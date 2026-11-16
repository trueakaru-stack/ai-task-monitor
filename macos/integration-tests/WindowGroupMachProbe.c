#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdio.h>

int main(void) {
    const char *blocked[] = {"com.apple.cfprefsd.agent", "com.apple.cfprefsd.daemon", "com.apple.bsd.dirhelper"};
    for (unsigned i = 0; i < sizeof(blocked) / sizeof(blocked[0]); ++i) {
        mach_port_t service = MACH_PORT_NULL;
        kern_return_t result = bootstrap_look_up(bootstrap_port, blocked[i], &service);
        if (result == KERN_SUCCESS) {
            mach_port_deallocate(mach_task_self(), service);
            fprintf(stderr, "A blocked profile service was reachable.\n");
            return 1;
        }
        if (result != BOOTSTRAP_NOT_PRIVILEGED) {
            fprintf(stderr, "Profile service denial could not be verified: %d.\n", result);
            return 1;
        }
    }
    mach_port_t window_server = MACH_PORT_NULL;
    kern_return_t result = bootstrap_look_up(bootstrap_port, "com.apple.windowserver.active", &window_server);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "The synthetic window service is unavailable: %d.\n", result);
        return 1;
    }
    mach_port_deallocate(mach_task_self(), window_server);
    puts("Profile services denied; synthetic window service reachable.");
    return 0;
}
