#define AEROSPACE_H

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

typedef struct aerospace aerospace;

aerospace* aerospace_new(const char* socketPath);

// Same, with an explicit connect budget. attempts <= 0 uses the startup
// default. Pass 1 when AeroSpace cannot possibly be coming up: the default
// budget sleeps a second between tries and blocks the caller for ~30 s.
aerospace* aerospace_new_attempts(const char* socketPath, int attempts);

int aerospace_is_initialized(aerospace* client);

void aerospace_close(aerospace* client);

char* aerospace_switch(aerospace* client, const char* direction);

char* aerospace_workspace(aerospace* client, int wrap_around, const char* ws_command, const char* stdin_payload);

char* aerospace_list_workspaces(aerospace* client, bool include_empty);

char* aerospace_exec(aerospace* client, const char** args, int arg_count,
	const char* expected_output_field);
