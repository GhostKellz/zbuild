#include <stdio.h>
#include "utils.h"

int main(int argc, char *argv[]) {
    printf("zbuild Example Project\n");
    printf("Version: %s\n", get_version());

    if (argc > 1) {
        printf("Arguments:\n");
        for (int i = 1; i < argc; i++) {
            printf("  [%d]: %s\n", i, argv[i]);
        }
    }

    int result = calculate(10, 20);
    printf("10 + 20 = %d\n", result);

    return 0;
}