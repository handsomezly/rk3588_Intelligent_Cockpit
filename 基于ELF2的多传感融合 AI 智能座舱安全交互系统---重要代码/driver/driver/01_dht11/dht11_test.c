#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/ioctl.h>

#define DEVICE_PATH "/dev/dht11"
#define DHT11_IOCTL_READ _IOR(0x88, 1, char[4])

int main()
{
    int fd;
    float humidity, temperature;
    char data[4];

    fd = open(DEVICE_PATH, O_RDONLY);
    if (fd < 0) {
        perror("Failed to open device");
        return 1;
    }

    if (ioctl(fd, DHT11_IOCTL_READ, data) < 0) {
        perror("Failed to read data via ioctl");
        close(fd);
        return 1;
    }

    humidity = data[0] + data[1] / 10.0;
    temperature = data[2] + data[3] / 10.0;

    printf("Humidity: %.1f%%\n", humidity);
    printf("Temperature: %.1f°C\n", temperature);

    close(fd);
    return 0;
}
