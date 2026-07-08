#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

typedef struct {
        short x_t;
        short y_t;
        short z_t;
        short a_x;
        short a_y;
        short a_z;
        short temp;
}sensor_data_t;

typedef struct {
        float x_t;
        float y_t;
        float z_t;
        float a_x;
        float a_y;
        float a_z;
        float temp;
}data_t;

void print_usage()
{
	printf("example :  ./app /dev/mpu6050 1"
			"\n\t'/dev/paj7620' sensor device PATH\n"
	      );
}


float Scale_Transform(float Sample_Value, float URV, float LRV)
{
    float Data;            
    float Value_L = -32767.0; 
    float Value_U = 32767.0;  

    Data = (Sample_Value - Value_L) / (Value_U - Value_L) * (URV - LRV) + LRV;

    return Data;
}

void conv_data(sensor_data_t *sensor , data_t *data)
{
	data->x_t = Scale_Transform((float)sensor->x_t , 2000.0 , -2000.0);
	data->y_t = Scale_Transform((float)sensor->y_t , 2000.0 , -2000.0);
	data->z_t = Scale_Transform((float)sensor->z_t , 2000.0 , -2000.0);

	data->a_x = Scale_Transform((float)sensor->a_x , 2.0 , -2.0);
	data->a_y = Scale_Transform((float)sensor->a_y , 2.0 , -2.0);
	data->a_z = Scale_Transform((float)sensor->a_z , 2.0 , -2.0);

	data->temp = (float)sensor->temp/340 + 36.53; 
}

void conv_data_2(sensor_data_t *sensor , data_t *data)
{
	data->x_t = (float)sensor->x_t/16.40;
	data->y_t = (float)sensor->y_t/16.40;
	data->z_t = (float)sensor->z_t/16.40;

	data->a_x = (float)sensor->a_x/2048;
	data->a_y = (float)sensor->a_y/2048;
	data->a_z = (float)sensor->a_z/2048;

	data->temp = (float)sensor->temp/340 + 36.53; 
}

int main(int argc , char **argv)
{
	int fd;
	short temp;
	sensor_data_t sensor;
	data_t data;
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

        fd = open(argv[1], O_RDWR);
        if (fd < 0)
        {
                exit(0);
        }
        while(1)
        {
		read(fd,&sensor,sizeof(sensor_data_t));
		conv_data(&sensor , &data);
		printf("x_t=%8.2f°/S y_t=%8.2f°/S z_t=%8.2f°/S a_x=%6.2fg a_y=%6.2fg a_z=%6.2fg temp=%6.2f°/C\n",data.x_t,data.y_t,data.z_t,data.a_x,data.a_y,data.a_z,data.temp);
		printf("\033[1A");
	//	printf("x_t=%8d°/S y_t=%8d°/S z_t=%8d°/S a_x=%6dg a_y=%6dg a_z=%6dg temp=%6d°/C\n",sensor.x_t,sensor.y_t,sensor.z_t,sensor.a_x,sensor.a_y,sensor.a_z,sensor.temp);
	//	printf("\033[1A");
                usleep(100000);
	}

	return 0;
}
