#include <linux/module.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/i2c.h>
#include <linux/ioctl.h>
#include <linux/delay.h>
#include <linux/of.h>
#include <linux/of_device.h>
#define IOC_MLX_READ_AMBIENT _IOR('M', 0, int)
#define IOC_MLX_READ_OBJECT  _IOR('M', 1, int)

#define MLX90614_TA      0x06      // 环境温度寄存器
#define MLX90614_TOBJ1   0x07      // 物体温度寄存器

static struct i2c_client *mlx90614_client;
static dev_t dev_id;
static struct cdev mlx_cdev;
static struct class *mlx90614_class;

static int mlx90614_read_temp(u8 reg, int *temp_scaled)
{
    u8 cmd = reg;
    u8 buf[3];  // 2字节数据 + 1字节PEC，可忽略
    struct i2c_msg msgs[2];
	int ret;
	u16 raw;
	int temp;
    // 写寄存器地址
    msgs[0].addr = mlx90614_client->addr;
    msgs[0].flags = 0;
    msgs[0].len = 1;
    msgs[0].buf = &cmd;

    // 读返回值
    msgs[1].addr = mlx90614_client->addr;
    msgs[1].flags = I2C_M_RD;
    msgs[1].len = 3;
    msgs[1].buf = buf;

    ret = i2c_transfer(mlx90614_client->adapter, msgs, 2);
    if (ret != 2) {
        pr_err("mlx90614: i2c_transfer failed (%d)\n", ret);
        return ret < 0 ? ret : -EIO;
    }

    raw = buf[0] | (buf[1] << 8);
    temp = (raw * 2) - 27315;
    *temp_scaled = (int)(temp * 100);

    pr_info("mlx90614: reg=0x%02x raw=0x%04x temp=%d°C\n", reg, raw, temp);
    return 0;
}

/* IOCTL接口 */
static long mlx90614_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    int temp_scaled;
    int ret;

    switch (cmd) {
        case IOC_MLX_READ_AMBIENT:
            ret = mlx90614_read_temp(MLX90614_TA, &temp_scaled);
            break;
        case IOC_MLX_READ_OBJECT:
            ret = mlx90614_read_temp(MLX90614_TOBJ1, &temp_scaled);
            break;
        default:
            return -ENOTTY;
    }

    if (ret)
        return ret;

    if (copy_to_user((int __user *)arg, &temp_scaled, sizeof(int)))
        return -EFAULT;

    return 0;
}

/* 文件操作结构体 */
static struct file_operations mlx90614_fops = {
    .owner = THIS_MODULE,
    .unlocked_ioctl = mlx90614_ioctl,
};

/* 设备树匹配表 */
static const struct of_device_id mlx90614_of_match[] = {
    { .compatible = "Amiya,mlx90614" },
    {},
};
MODULE_DEVICE_TABLE(of, mlx90614_of_match);

/* 驱动探测函数 */
/* 驱动探测函数 */
static int mlx90614_probe(struct i2c_client *client, const struct i2c_device_id *id)
{
    int ret;

    pr_info("MLX90614 driver probe\n");

    /* 检查设备树节点 */
    if (!i2c_of_match_device(mlx90614_of_match, client)) {
        pr_err("Device tree matching failed\n");
        return -ENODEV;
    }

    /* 初始化字符设备 */
    ret = alloc_chrdev_region(&dev_id, 0, 1, "mlx90614");
    if (ret) {
        pr_err("Failed to alloc chrdev region\n");
        return ret;
    }

    cdev_init(&mlx_cdev, &mlx90614_fops);
    ret = cdev_add(&mlx_cdev, dev_id, 1);
    if (ret) {
        unregister_chrdev_region(dev_id, 1);
        return ret;
    }

    /* 创建设备节点 */
    mlx90614_class = class_create(THIS_MODULE, "mlx90614");
    device_create(mlx90614_class, NULL, dev_id, NULL, "mlx90614");

    mlx90614_client = client;
    pr_info("Probe success on I2C addr 0x%02x\n", client->addr);
    return 0;
}
/* 驱动移除函数 */
static int mlx90614_remove(struct i2c_client *client)
{
    device_destroy(mlx90614_class, dev_id);
    class_destroy(mlx90614_class);
    cdev_del(&mlx_cdev);
    unregister_chrdev_region(dev_id, 1);
    return 0;
}

/* I2C设备ID表 */
static const struct i2c_device_id mlx90614_ids[] = {
    { "mlx90614", 0 },
    {}
};
MODULE_DEVICE_TABLE(i2c, mlx90614_ids);

/* I2C驱动结构体 */
static struct i2c_driver mlx90614_driver = {
    .driver = {
        .name   = "mlx90614",
        .of_match_table = mlx90614_of_match,
    },
    .probe      = mlx90614_probe,
    .remove     = mlx90614_remove,
    .id_table   = mlx90614_ids,
};

module_i2c_driver(mlx90614_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Amiya");
MODULE_DESCRIPTION("MLX90614 I2C Driver with Device Tree Support");
