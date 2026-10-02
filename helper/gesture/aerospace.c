#include <errno.h>
#include <pthread.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include "aerospace.h"
#include "yyjson.h"

#define CLI_BUFFER_SIZE 8192
#define MAX_FRAME_SIZE (16 * 1024 * 1024)
#define SOCKET_CONNECT_MAX_ATTEMPTS 30
#define SOCKET_CONNECT_RETRY_USEC 1000000
#define SOCKET_IO_TIMEOUT_SEC 5
#define SOCKET_PROTOCOL_VERSION 1

static const char* ERROR_SOCKET_CREATE = "Failed to create Unix domain socket";
static const char* ERROR_SOCKET_SEND = "Failed to send data through socket";
static const char* ERROR_SOCKET_RECEIVE = "Failed to receive data from socket";
static const char* ERROR_SOCKET_CLOSE = "Failed to close socket connection";
static const char* ERROR_JSON_PRINT = "Failed to print JSON to string";
static const char* WARN_CLI_FALLBACK = "Warning: Failed to connect to socket at %s: %s (errno %d). Falling back to CLI.\n";

struct aerospace {
	int fd;
	char* socket_path;
	bool use_cli_fallback;
	pthread_mutex_t command_mutex;
};

static void fatal_error(const char* fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	fprintf(stderr, "Fatal Error: ");
	vfprintf(stderr, fmt, args);
	if (errno != 0)
		fprintf(stderr, ": %s (errno %d)", strerror(errno), errno);
	fprintf(stderr, "\n");
	va_end(args);
	exit(EXIT_FAILURE);
}

static bool write_exact(int fd, const void* buffer, size_t size)
{
	const char* cursor = buffer;
	while (size > 0) {
		ssize_t written = write(fd, cursor, size);
		if (written < 0) {
			if (errno == EINTR)
				continue;
			return false;
		}
		if (written == 0) {
			errno = EPIPE;
			return false;
		}
		cursor += written;
		size -= (size_t)written;
	}
	return true;
}

static bool read_exact(int fd, void* buffer, size_t size)
{
	char* cursor = buffer;
	while (size > 0) {
		ssize_t bytes_read = read(fd, cursor, size);
		if (bytes_read < 0) {
			if (errno == EINTR)
				continue;
			return false;
		}
		if (bytes_read == 0) {
			errno = ECONNRESET;
			return false;
		}
		cursor += bytes_read;
		size -= (size_t)bytes_read;
	}
	return true;
}

static bool perform_protocol_handshake(aerospace* client)
{
	uint32_t client_version = SOCKET_PROTOCOL_VERSION;
	uint32_t server_version = 0;

	if (!write_exact(client->fd, &client_version, sizeof(client_version)) ||
		!read_exact(client->fd, &server_version, sizeof(server_version))) {
		return false;
	}

	if (server_version != SOCKET_PROTOCOL_VERSION) {
		fprintf(stderr, "Unsupported AeroSpace socket protocol version %u (expected %u).\n",
			server_version, SOCKET_PROTOCOL_VERSION);
		errno = EPROTONOSUPPORT;
		return false;
	}

	return true;
}

static bool configure_socket_timeouts(int fd)
{
	struct timeval timeout = {
		.tv_sec = SOCKET_IO_TIMEOUT_SEC,
		.tv_usec = 0,
	};
	return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
		setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0;
}

static char* get_default_socket_path(void)
{
	uid_t uid = getuid();
	struct passwd* pw = getpwuid(uid);

	if (uid == 0) {
		const char* sudo_user = getenv("SUDO_USER");
		if (sudo_user) {
			struct passwd* pw_temp = getpwnam(sudo_user);
			if (pw_temp)
				pw = pw_temp;
		} else {
			const char* user_env = getenv("USER");
			if (user_env && strcmp(user_env, "root") != 0) {
				struct passwd* pw_temp = getpwnam(user_env);
				if (pw_temp)
					pw = pw_temp;
			}
		}
	}

	if (!pw)
		fatal_error("Unable to determine user information for default socket path");

	const char* username = pw->pw_name;
	size_t len = snprintf(NULL, 0, "/tmp/bobko.aerospace-%s.sock", username);
	char* path = malloc(len + 1);
	snprintf(path, len + 1, "/tmp/bobko.aerospace-%s.sock", username);
	return path;
}

// A launch agent's PATH does not include Homebrew, so the bare
// "aerospace" this fallback used resolved to nothing: every fallback
// command died as `sh: aerospace: command not found` while the daemon
// itself looked perfectly healthy. Resolve it once, absolutely.
static const char* aerospace_cli_path(void)
{
	static char resolved[256];
	if (resolved[0])
		return resolved;
	const char* candidates[] = { "/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace" };
	for (size_t i = 0; i < sizeof candidates / sizeof candidates[0]; i++)
		if (access(candidates[i], X_OK) == 0) {
			snprintf(resolved, sizeof resolved, "%s", candidates[i]);
			return resolved;
		}
	snprintf(resolved, sizeof resolved, "aerospace"); // last resort: PATH
	return resolved;
}

static bool aerospace_open_socket(aerospace* client, int attempts);

static char* execute_cli_command(const char* command_string, int* exit_code)
{
	FILE* pipe = popen(command_string, "r");
	if (!pipe) {
		fatal_error("popen() failed for command '%s'", command_string);
	}

	char* output = malloc(CLI_BUFFER_SIZE + 1);
	if (!output) {
		pclose(pipe);
		fatal_error("Failed to allocate buffer for CLI output");
	}

	size_t nread = fread(output, 1, CLI_BUFFER_SIZE, pipe);
	output[nread] = '\0';

	int status = pclose(pipe);
	*exit_code = -1;
	if (status != 0) {
		if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
			*exit_code = WEXITSTATUS(status);
			fprintf(stderr, "Warning: CLI command failed with exit code %d: %s\n", *exit_code, command_string);
		} else if (status == -1) {
			fprintf(stderr, "Warning: pclose failed: %s\n", strerror(errno));
		}
	} else
		*exit_code = 0;

	if (nread > 0 && output[nread - 1] == '\n') {
		output[nread - 1] = '\0';
	}

	return output;
}

static char* execute_socket_command(aerospace* client, const char** args, int arg_count,
	const char* stdin_payload, const char* stdin_flag, const char* expected_output_field,
	bool* transport_ok)
{
	*transport_ok = false;

	yyjson_mut_doc* doc = yyjson_mut_doc_new(NULL);
	yyjson_mut_val* root = yyjson_mut_obj(doc);
	yyjson_mut_doc_set_root(doc, root);
	yyjson_mut_val* args_array = yyjson_mut_arr(doc);
	for (int i = 0; i < arg_count; i++) {
		yyjson_mut_arr_add_str(doc, args_array, args[i]);
	}
	if (stdin_flag)
		yyjson_mut_arr_add_str(doc, args_array, stdin_flag);
	yyjson_mut_obj_add_val(doc, root, "args", args_array);
	yyjson_mut_obj_add_str(doc, root, "stdin", stdin_payload ? stdin_payload : "");
	yyjson_mut_obj_add_null(doc, root, "windowId");
	yyjson_mut_obj_add_null(doc, root, "workspace");
	size_t len;
	const char* json_str = yyjson_mut_write(doc, 0, &len);
	yyjson_mut_doc_free(doc);
	if (!json_str)
		fatal_error(ERROR_JSON_PRINT);

	if (len > UINT32_MAX) {
		free((void*)json_str);
		fprintf(stderr, "Error: AeroSpace request is too large.\n");
		return NULL;
	}

	uint32_t request_size = (uint32_t)len;
	if (!write_exact(client->fd, &request_size, sizeof(request_size)) ||
		!write_exact(client->fd, json_str, len)) {
		free((void*)json_str);
		fprintf(stderr, "%s: %s (errno %d)\n", ERROR_SOCKET_SEND, strerror(errno), errno);
		return NULL;
	}
	free((void*)json_str);

	uint32_t response_size = 0;
	if (!read_exact(client->fd, &response_size, sizeof(response_size))) {
		fprintf(stderr, "%s: %s (errno %d)\n", ERROR_SOCKET_RECEIVE, strerror(errno), errno);
		return NULL;
	}

	if (response_size == 0 || response_size > MAX_FRAME_SIZE) {
		fprintf(stderr, "Error: Invalid AeroSpace response size: %u.\n", response_size);
		return NULL;
	}

	char* response = malloc(response_size);
	if (!response)
		fatal_error("Failed to allocate AeroSpace response buffer");
	if (!read_exact(client->fd, response, response_size)) {
		free(response);
		fprintf(stderr, "%s: %s (errno %d)\n", ERROR_SOCKET_RECEIVE, strerror(errno), errno);
		return NULL;
	}

	yyjson_doc* resp_doc = yyjson_read(response, response_size, 0);
	free(response);
	if (!resp_doc) {
		fprintf(stderr, "Error: Failed to parse AeroSpace response.\n");
		return NULL;
	}

	yyjson_val* resp_root = yyjson_doc_get_root(resp_doc);
	char* result = NULL;
	yyjson_val* exit_code_item = yyjson_obj_get(resp_root, "exitCode");
	if (!yyjson_is_int(exit_code_item)) {
		fprintf(stderr, "Response does not contain valid exitCode field\n");
		yyjson_doc_free(resp_doc);
		return NULL;
	}

	int exit_code = (int)yyjson_get_int(exit_code_item);
	if (exit_code != 0) {
		yyjson_val* output_item = yyjson_obj_get(resp_root, "stderr");
		if (yyjson_is_str(output_item))
			result = strdup(yyjson_get_str(output_item));
	} else if (expected_output_field) {
		yyjson_val* output_item = yyjson_obj_get(resp_root, expected_output_field);
		if (yyjson_is_str(output_item))
			result = strdup(yyjson_get_str(output_item));
	}

	*transport_ok = true;
	yyjson_doc_free(resp_doc);
	return result;
}

static char* execute_aerospace_command(aerospace* client, const char** args, int arg_count, const char* stdin_payload, const char* expected_output_field)
{
	if (!client || !args || arg_count == 0) {
		errno = EINVAL;
		fprintf(stderr, "execute_aerospace_command: Invalid arguments\n");
		return NULL;
	}

	// AeroSpace v0.20.0+ requires workspace commands to declare whether
	// they consume the stdin payload, for both CLI and socket requests.
	const char* stdin_flag = NULL;
	if (strcmp(args[0], "workspace") == 0 && arg_count > 1 &&
		(strcmp(args[1], "next") == 0 || strcmp(args[1], "prev") == 0))
		stdin_flag = (stdin_payload && strlen(stdin_payload) > 0) ? "--stdin" : "--no-stdin";

	pthread_mutex_lock(&client->command_mutex);

	// A transport failure is not a life sentence. One socket read
	// timeout — which is what a display reconfiguration produced —
	// used to strand the daemon in CLI mode for the rest of the
	// session; every swipe after docking silently did nothing. If we
	// have no fd, try the socket again before settling for the CLI.
	if (client->fd < 0 && aerospace_open_socket(client, 1))
		client->use_cli_fallback = false;

	if (client->use_cli_fallback) {
		const char* cli_bin = aerospace_cli_path();
		size_t total_len = strlen(cli_bin);
		for (int i = 0; i < arg_count; i++) {
			total_len += 1 + strlen(args[i]);
		}
		if (stdin_flag) {
			total_len += 1 + strlen(stdin_flag);
		}

		char* cli_command_base = malloc(total_len + 1);
		if (!cli_command_base) {
			fatal_error("Failed to allocate memory for CLI command");
		}

		char* p = cli_command_base;
		p += sprintf(p, "%s", cli_bin);
		for (int i = 0; i < arg_count; i++) {
			p += sprintf(p, " %s", args[i]);
		}
		if (stdin_flag) {
			p += sprintf(p, " %s", stdin_flag);
		}

		char* final_command;
		if (stdin_payload && strlen(stdin_payload) > 0) {
			const char* format = "echo '%s' | %s";
			size_t len = snprintf(NULL, 0, format, stdin_payload, cli_command_base);
			final_command = malloc(len + 1);
			snprintf(final_command, len + 1, format, stdin_payload, cli_command_base);
			free(cli_command_base);
		} else {
			final_command = cli_command_base;
		}

		int exit_code;
		char* result = execute_cli_command(final_command, &exit_code);
		free(final_command);
		if (exit_code != 0) {
			free(result);
			result = expected_output_field ? NULL : strdup("AeroSpace CLI command failed");
		} else if (!expected_output_field) {
			free(result);
			result = NULL;
		}
		pthread_mutex_unlock(&client->command_mutex);
		return result;
	}

	bool transport_ok = false;
	char* result = execute_socket_command(client, args, arg_count, stdin_payload,
		stdin_flag, expected_output_field, &transport_ok);
	if (!transport_ok) {
		close(client->fd);
		client->fd = -1;
		client->use_cli_fallback = true;
		if (!expected_output_field)
			result = strdup("AeroSpace socket communication failed");
	}

	pthread_mutex_unlock(&client->command_mutex);
	return result;
}

// Connect and negotiate, `attempts` times with backoff. Startup gives
// it the full budget because AeroSpace may not be up yet at login; a
// mid-session reconnect gets one shot, because it runs on the gesture
// path and a swipe must not block.
static bool aerospace_open_socket(aerospace* client, int attempts)
{
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(struct sockaddr_un));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, client->socket_path, sizeof(addr.sun_path) - 1);
	addr.sun_path[sizeof(addr.sun_path) - 1] = '\0';

	int connect_errno = 0;
	for (int attempt = 0; attempt < attempts; attempt++) {
		errno = 0;
		client->fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if (client->fd < 0) {
			connect_errno = errno;
			// used to be fatal; a daemon that dies here loses every
			// gesture, and the CLI fallback can carry the session
			fprintf(stderr, "%s: %s (errno %d)\n", ERROR_SOCKET_CREATE,
				strerror(connect_errno), connect_errno);
			break;
		}

		errno = 0;
		if (connect(client->fd, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
			connect_errno = 0;
			break;
		}
		connect_errno = errno;
		close(client->fd);
		client->fd = -1;
		if (attempt + 1 < attempts) {
			usleep(SOCKET_CONNECT_RETRY_USEC);
		}
	}

	if (connect_errno != 0) {
		if (client->fd >= 0) {
			close(client->fd);
			client->fd = -1;
		}
		return false;
	}
	if (!configure_socket_timeouts(client->fd) || !perform_protocol_handshake(client)) {
		close(client->fd);
		client->fd = -1;
		return false;
	}
	return true;
}

aerospace* aerospace_new(const char* socketPath)
{
	return aerospace_new_attempts(socketPath, 0);
}

aerospace* aerospace_new_attempts(const char* socketPath, int attempts)
{
	aerospace* client = malloc(sizeof(aerospace));
	if (!client)
		fatal_error("Failed to allocate AeroSpace client");

	client->fd = -1;
	client->use_cli_fallback = false;
	int mutex_error = pthread_mutex_init(&client->command_mutex, NULL);
	if (mutex_error != 0) {
		free(client);
		errno = mutex_error;
		fatal_error("Failed to initialize AeroSpace command mutex");
	}

	if (socketPath)
		client->socket_path = strdup(socketPath);
	else
		client->socket_path = get_default_socket_path();

	// AeroSpace may not be ready when we start (e.g. at login). Retry the
	// connect with bounded backoff before giving up and falling back to CLI,
	// otherwise we get stuck in CLI mode for the entire session.
	if (attempts <= 0)
		attempts = SOCKET_CONNECT_MAX_ATTEMPTS;
	if (!aerospace_open_socket(client, attempts)) {
		int why = errno;
		fprintf(stderr, WARN_CLI_FALLBACK, client->socket_path, strerror(why), why);
		client->use_cli_fallback = true;
	}

	return client;
}

int aerospace_is_initialized(aerospace* client)
{
	return (client && (client->fd >= 0 || client->use_cli_fallback));
}

void aerospace_close(aerospace* client)
{
	if (client) {
		pthread_mutex_lock(&client->command_mutex);
		if (client->fd >= 0) {
			errno = 0;
			if (close(client->fd) < 0) {
				fprintf(stderr, "%s: %s (errno %d)\n", ERROR_SOCKET_CLOSE, strerror(errno), errno);
			}
			client->fd = -1;
		}
		free(client->socket_path);
		client->socket_path = NULL;
		pthread_mutex_unlock(&client->command_mutex);
		pthread_mutex_destroy(&client->command_mutex);
		free(client);
	}
}

char* aerospace_switch(aerospace* client, const char* direction)
{
	return aerospace_workspace(client, 0, direction, "");
}

char* aerospace_workspace(aerospace* client, int wrap_around, const char* ws_command,
	const char* stdin_payload)
{
	const char* args[3] = { "workspace", ws_command };
	int arg_count = 2;
	if (wrap_around) {
		args[arg_count++] = "--wrap-around";
	}
	return execute_aerospace_command(client, args, arg_count, stdin_payload, NULL);
}

char* aerospace_list_workspaces(aerospace* client, bool include_empty)
{
	if (include_empty) {
		const char* args[] = { "list-workspaces", "--monitor", "focused" };
		return execute_aerospace_command(client, args, 3, "", "stdout");
	} else {
		const char* args[] = { "list-workspaces", "--monitor", "focused", "--empty", "no" };
		return execute_aerospace_command(client, args, 5, "", "stdout");
	}
}

char* aerospace_exec(aerospace* client, const char** args, int arg_count,
	const char* expected_output_field)
{
	return execute_aerospace_command(client, args, arg_count, "", expected_output_field);
}
