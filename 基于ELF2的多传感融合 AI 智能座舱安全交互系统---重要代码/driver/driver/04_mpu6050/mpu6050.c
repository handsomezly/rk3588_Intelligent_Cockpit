#include <linux/init.h>
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/uaccess.h>
#include <linux/i2c.h>
#include <linux/types.h>
#include <linux/kernel.h>
#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/gpio.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/of_gpio.h>
#include <asm/io.h>
#include <linux/device.h>
#include <linux/platform_device.h>
#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 1, 99)
#include <linux/ide.h>
#endif


#include "mpu6050.h"

#define DEV_NAME "mpu6050"
#define DEV_CNT (1)

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
	dev_t devid;
	struct cdev cdev;
	struct class *class;
	struct device *device;
	struct device_node *nd;
	int major;
	void *private_data;
	sensor_data_t sensor_data;
}mpu6050_dev_t;

mpu6050_dev_t mpu6050dev;

static s32 mpu6050_write_regs(mpu6050_dev_t *dev, u8 reg, u8 *buf, u8 len)
{
	u8 byte[256] = {0};
	struct i2c_msg msg;
	struct i2c_client *client = (struct i2c_client*)dev->private_data;

	byte[0] = reg;
	memcpy(&byte[1], buf, len);

	msg.addr = client->addr;
	msg.flags = 0;
	msg.buf = byte;
	msg.len = len + 1;

	return i2c_transfer(client->adapter, &msg, 1);
}

static int mpu6050_read_regs(mpu6050_dev_t *dev, u8 reg, void *val, int len)
{
	int ret = 0;

	struct i2c_msg msg[2];
	struct i2c_client *client = (struct i2c_client*)dev->private_data;


	msg[0].addr = client->addr;
	msg[0].flags = 0;
	msg[0].buf = &reg;
	msg[0].len = 1;


	msg[1].addr = client->addr;
	msg[1].flags = I2C_M_RD;
	msg[1].buf = val;
	msg[1].len = len;

	ret = i2c_transfer(client->adapter, msg, 2);
	if (ret == 2)   ret = 0;
	else ret = -EREMOTEIO;

	return ret;
}

static void mpu6050_write_reg(mpu6050_dev_t *dev, u8 reg, u8 data)
{
	u8 buf = 0;
	buf = data;
	mpu6050_write_regs(dev, reg, &buf, 1);
}
static unsigned char mpu6050_read_reg(mpu6050_dev_t *dev, u8 reg)
{
	u8 data = 0;
	mpu6050_read_regs(dev, reg, &data, 1);
	return data;
#if 0
	struct i2c_client *client = (struct i2c_client *)dev->private_data;
	return i2c_smbus_read_byte_data(client, reg);
#endif
}

static void mpu6050dev_init(mpu6050_dev_t *dev)
{
	mpu6050_write_reg(dev,PWR_MGMT_1,0x00);
	mpu6050_write_reg(dev,SMPLRT_DIV,0x07);
	mpu6050_write_reg(dev,CONFIG,0x06);
	mpu6050_write_reg(dev,GYRO_CONFIG,0x18);
	mpu6050_write_reg(dev,ACCEL_CONFIG,0x00);
}

static int mpu6050_open(struct inode *inode, struct file *filp)
{
	filp->private_data = &mpu6050dev;
	return 0;
}

static ssize_t mpu6050_read(struct file *filp, char __user *buf, size_t cnt, loff_t *off)
{
	int ret;
	unsigned char _data[2];	
	mpu6050_dev_t *dev = filp->private_data;

	if (cnt < sizeof(sensor_data_t))
		return -EINVAL;
		
	_data[0] = mpu6050_read_reg(dev,GYRO_XOUT_L);
	_data[1] = mpu6050_read_reg(dev,GYRO_XOUT_H);
	dev->sensor_data.x_t = (((unsigned short)_data[1] << 8) & 0xFF00) | _data[0];

	_data[0] = mpu6050_read_reg(dev,GYRO_YOUT_L);
        _data[1] = mpu6050_read_reg(dev,GYRO_YOUT_H);
        dev->sensor_data.y_t = (((unsigned short)_data[1] << 8) & 0xFF00) | _data[0];

	_data[0] = mpu6050_read_reg(dev,GYRO_ZOUT_L);
        _data[1] = mpu6050_read_reg(dev,GYRO_ZOUT_H);
        dev->sensor_data.z_t = (((unsigned short)_data[1] << 8) & 0xFF00) | _data[0];

	
	_data[0] = mpu6050_read_reg(dev,ACCEL_XOUT_L);
        _data[1] = mpu6050_read_reg(dev,ACCEL_XOUT_H);
        dev->sensor_data.a_x = (((unsigned short)_data[1] << 8) & 0xFF00) | _data[0];

	_data[0] = mpu6050_read_reg(dev,ACCEL_YOUT_L);
        _data[1] = mpu6050_read_reg(dev,ACCEL_YOUT_H);
        dev->sensor_data.a_y = (((unsigned short)_data[1] << 8) & 0xFF00) | _data[0];

	_data[0] = mpu6050_read_reg(dev,ACCEL_ZOUT_L);
        _data[1] = mpu6050_read_reg(dev,ACCEL_ZOUT_H);
        dev->sensor_data.a_z = (((unsigned short)_data[1] << 8) & 0xFF00) | _data[0];
	

	_data[0] = mpu6050_read_reg(dev,TEMP_OUT_L);
        _data[1] = mpu6050_read_reg(dev,TEMP_OUT_H);
        dev->sensor_data.temp = (((unsigned short)_data[1] << 8) & 0xFF00) | _data[0];
	ret = copy_to_user(buf,&dev->sensor_data,sizeof(sensor_data_t));
	if (ret)
		return -EFAULT;

	return sizeof(sensor_data_t);
}

static int mpu6050_release(struct inode *inode, struct file *filp)
{
	return 0;
}

static struct file_operations mpu6050_chr_dev_fops =
{
	.owner = THIS_MODULE,
	.open = mpu6050_open,
	.read = mpu6050_read,
	.release = mpu6050_release,
};

static int mpu6050_probe(struct i2c_client *client,const struct i2c_device_id *id)
{
	int ret = -1;
	ret = alloc_chrdev_region(&mpu6050dev.devid, 0, DEV_CNT, DEV_NAME);
	if (ret < 0)
	{
		printk("fail to alloc mpu6050_dev\n");
		goto alloc_err;
	}

	cdev_init(&mpu6050dev.cdev, &mpu6050_chr_dev_fops);
	ret = cdev_add(&mpu6050dev.cdev, mpu6050dev.devid, DEV_CNT);
	if (ret < 0)
	{
		printk("fail to add cdev\n");
		goto add_err;
	}

	mpu6050dev.class = class_create(THIS_MODULE, DEV_NAME);
	mpu6050dev.device = device_create(mpu6050dev.class, NULL, mpu6050dev.devid, NULL, DEV_NAME);
	mpu6050dev.private_data = client;
	mpu6050dev_init(&mpu6050dev);
	return 0;

add_err:
	unregister_chrdev_region(mpu6050dev.devid, DEV_CNT);
	printk("\n add_err error! \n");
alloc_err:
	return ret;
}
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 1, 99)
static int mpu6050_remove(struct i2c_client *client)
{
	device_destroy(mpu6050dev.class, mpu6050dev.devid);
	class_destroy(mpu6050dev.class);
	cdev_del(&mpu6050dev.cdev);
	unregister_chrdev_region(mpu6050dev.devid, DEV_CNT);
	return 0;
}
#else
static void mpu6050_remove(struct i2c_client *client)
{
	device_destroy(mpu6050dev.class, mpu6050dev.devid);
	class_destroy(mpu6050dev.class);
	cdev_del(&mpu6050dev.cdev);
	unregister_chrdev_region(mpu6050dev.devid, DEV_CNT);
}
#endif

static struct of_device_id mpu6050_of_match[] = {
	{.compatible = "Amiya,mpu6050"},
	{},
};
MODULE_DEVICE_TABLE(of, mpu6050_of_match);

static struct i2c_device_id mpu6050_id[] = {
	{"elfboard,mpu6050",0},
	{},
};
MODULE_DEVICE_TABLE(i2c, mpu6050_id);

static struct i2c_driver mpu6050_driver = {
	.probe = mpu6050_probe,
	.remove = mpu6050_remove,
	.driver = {
		.owner = THIS_MODULE,
		.name = "mpu6050",
		.of_match_table = mpu6050_of_match,
	},
	.id_table = mpu6050_id,
};


static int __init mpu6050_init(void)
{
	int ret = 0;
	ret = i2c_add_driver(&mpu6050_driver);
	return ret;
}

static void __exit mpu6050_exit(void)
{
	i2c_del_driver(&mpu6050_driver);
}

module_init(mpu6050_init);
module_exit(mpu6050_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("YourName");
MODULE_DESCRIPTION("mpu6050 sensor driver");
