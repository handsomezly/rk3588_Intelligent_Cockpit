#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

void print_usage()
{
	printf("example :  ./app /dev/bh1750"
			"\n\t'/dev/bh1750' sensor device PATH\n"
	      );
}

int main(int argc, char *argv[])
{
	int fd;
	int ret;
	unsigned short data = 0;
	
	if(argc != 2)
	{
		print_usage();
		exit(1);
	}

	if ((!strcmp(argv[1], "--h")) || (!strcmp(argv[1], "--help")))
	{
		print_usage();
		exit(1);
	}
	
	char *dev = argv[1];
	fd = open(dev, O_RDWR);
	if (fd < 0)
	{
		exit(0);
	}

	while(1)
	{
		ret = read(fd, &data, sizeof(unsigned short));
		if(ret < 0)
		{
			perror("read error!\n");
			return -1;
		}

		printf("light data = %10.2f(lx)\n", (float)data/1.2);
		printf("\033[1A");
		sleep(1);
	}

	return 0;
}
