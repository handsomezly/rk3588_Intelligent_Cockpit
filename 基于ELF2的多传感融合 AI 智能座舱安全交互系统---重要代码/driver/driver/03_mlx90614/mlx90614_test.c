#include <stdio.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define IOC_MLX_READ_AMBIENT _IOR('M', 0, int)
#define IOC_MLX_READ_OBJECT  _IOR('M', 1, int)

int main()
{
    int fd = open("/dev/mlx90614", O_RDWR);
    if (fd < 0) {
        perror("Failed to open device");
        return -1;
    }

    int temp;

    if (ioctl(fd, IOC_MLX_READ_AMBIENT, &temp) == 0) {
        printf("Ambient: %.2f°C\n", temp / 10000.0);
    } else {
        perror("Failed to read ambient temperature");
    }

    if (ioctl(fd, IOC_MLX_READ_OBJECT, &temp) == 0) {
        printf("Object:  %.2f°C\n", temp / 10000.0);
    } else {
        perror("Failed to read object temperature");
    }

    close(fd);
    return 0;
}
