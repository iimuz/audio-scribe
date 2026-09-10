/*
 * launchd entry point for audio-scribe.
 * Runs only the script path baked in at compile time, via /bin/bash, and
 * accepts no arguments. macOS TCC (Full Disk Access) binds to this binary's
 * code identity, so a fixed, rarely rebuilt binary keeps the grant valid
 * while mise and the tools it manages are updated freely.
 */
#include <stdio.h>
#include <unistd.h>

#ifndef SCRIPT_PATH
#error "SCRIPT_PATH must be defined at compile time (-DSCRIPT_PATH=\"...\")"
#endif

int main(void) {
    execl("/bin/bash", "bash", SCRIPT_PATH, (char *)NULL);
    perror("execl /bin/bash");
    return 127;
}
