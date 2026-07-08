#include <linux/module.h>
#include <linux/fs.h>
#include <linux/platform_device.h>
#include <linux/miscdevice.h>
#include <linux/of_gpio.h>
#include <linux/gpio.h>
#include <linux/uaccess.h>
#include <linux/sysfs.h>
#include <linux/delay.h>
#include <linux/mutex.h>

#define DEVICE_NAME "dht11"
#define CLASS_NAME  "dht11"
#define DHT11_IOC_MAGIC 0x88
#define DHT11_IOCTL_READ _IOR(DHT11_IOC_MAGIC, 1, char[4])

static int dht11_gpio = -1;
static struct device *dht11_dev;
static int us_array[40];
static int time_array[40];
static int us_index;
static int us_low_array[40];
static int us_low_index;
static unsigned char data[5];
static struct mutex dht11_lock;

// 前向声明
static int dht11_read_data(void);

static ssize_t dht11_read(struct file *file, char __user *buf, size_t len, loff_t *offset)
{
    if (len < 4)
        return -EINVAL;

    if (mutex_lock_interruptible(&dht11_lock))
        return -ERESTARTSYS;

    if (dht11_read_data()) {
        mutex_unlock(&dht11_lock);
        return -EAGAIN;
    }

    if (copy_to_user(buf, data, 4)) {
        mutex_unlock(&dht11_lock);
        return -EFAULT;
    }

    mutex_unlock(&dht11_lock);
    return 4;
}

static long dht11_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    int ret = 0;
    switch (cmd) {
    case DHT11_IOCTL_READ:
        if (mutex_lock_interruptible(&dht11_lock))
            return -ERESTARTSYS;
        if (dht11_read_data()) {
            mutex_unlock(&dht11_lock);
            return -EAGAIN;
        }
        if (copy_to_user((char __user *)arg, data, 4)) {
            mutex_unlock(&dht11_lock);
            return -EFAULT;
        }
        mutex_unlock(&dht11_lock);
        break;
    default:
        ret = -EINVAL;
        break;
    }
    return ret;
}

static int dht11_reset(void)
{
    return gpio_direction_output(dht11_gpio, 1);
}

static int dht11_start(void)
{
    int ret;

    msleep(30);

    ret = gpio_direction_output(dht11_gpio, 0);
    if (ret)
        return ret;

    msleep(20);

    gpio_set_value(dht11_gpio, 1);
    udelay(40);

    ret = gpio_direction_input(dht11_gpio);
    if (ret)
        return ret;

    udelay(2);
    return 0;
}

static int dht11_wait_for_ready(void)
{
    int timeout_us = 20000;
    while (gpio_get_value(dht11_gpio) && --timeout_us)
        udelay(1);
    if (!timeout_us)
        return -1;

    timeout_us = 200;
    while (!gpio_get_value(dht11_gpio) && --timeout_us)
        udelay(1);
    if (!timeout_us)
        return -1;

    timeout_us = 200;
    while (gpio_get_value(dht11_gpio) && --timeout_us)
        udelay(1);
    if (!timeout_us)
        return -1;

    return 0;
}

static int dht11_read_byte(unsigned char *buf)
{
    int i;
    int us = 0;
    unsigned char data = 0;
    int timeout_us = 200;
    u64 pre, last;

    for (i = 0; i < 8; i++) {
        timeout_us = 400;
        us = 0;
        while (!gpio_get_value(dht11_gpio) && --timeout_us) {
            udelay(1);
            us++;
        }
        if (!timeout_us)
            return -1;
        us_low_array[us_low_index++] = us;

        timeout_us = 20000000;
        us = 0;
        pre = ktime_get_ns();
        while (gpio_get_value(dht11_gpio) && --timeout_us)
            ;
        last = ktime_get_ns();
        if (!timeout_us)
            return -1;
        us_array[us_index] = last - pre;
        time_array[us_index++] = 20000000 - timeout_us;

        if (last - pre > 40000) {
            data = (data << 1) | 1;
        } else {
            data = (data << 1) | 0;
        }
    }

    *buf = data;
    return 0;
}

static int dht11_read_data(void)
{
    int i;
    us_index = 0;
    us_low_index = 0;

    if (dht11_reset())
        return -1;

    if (dht11_start())
        return -1;

    if (dht11_wait_for_ready())
        return -1;

    for (i = 0; i < 5; i++) {
        if (dht11_read_byte(&data[i]))
            return -1;
    }

    if (data[4] != (unsigned char)(data[0] + data[1] + data[2] + data[3]))
        return -1;

    return 0;
}

static ssize_t humidity_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    int ret;
    if (mutex_lock_interruptible(&dht11_lock))
        return -ERESTARTSYS;
    ret = dht11_read_data();
    mutex_unlock(&dht11_lock);
    if (ret)
        return ret;
    return sprintf(buf, "%d.%d\n", data[0], data[1]);
}

static ssize_t temperature_show(struct device *dev, struct device_attribute *attr, char *buf)
{
    int ret;
    if (mutex_lock_interruptible(&dht11_lock))
        return -ERESTARTSYS;
    ret = dht11_read_data();
    mutex_unlock(&dht11_lock);
    if (ret)
        return ret;
    return sprintf(buf, "%d.%d\n", data[2], data[3]);
}

static DEVICE_ATTR_RO(humidity);
static DEVICE_ATTR_RO(temperature);

static const struct file_operations dht11_fops = {
    .owner = THIS_MODULE,
    .read = dht11_read,
    .unlocked_ioctl = dht11_ioctl,
};

static struct miscdevice dht11_miscdev = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = DEVICE_NAME,
    .fops  = &dht11_fops,
};

static int dht11_probe(struct platform_device *pdev)
{
    struct device_node *np = pdev->dev.of_node;
    int ret;

    pr_info("dht11: probe start\n");

    mutex_init(&dht11_lock);

    dht11_gpio = of_get_named_gpio(np, "data-gpios", 0);
    if (!gpio_is_valid(dht11_gpio)) {
        dev_err(&pdev->dev, "invalid GPIO from DT\n");
        return -EINVAL;
    }

    ret = devm_gpio_request_one(&pdev->dev, dht11_gpio, GPIOF_OUT_INIT_HIGH, "dht11_gpio");
    if (ret) {
        dev_err(&pdev->dev, "failed to request gpio\n");
        return ret;
    }

    ret = misc_register(&dht11_miscdev);
    if (ret) {
        dev_err(&pdev->dev, "failed to register misc device\n");
        return ret;
    }

    dht11_dev = dht11_miscdev.this_device;
    device_create_file(dht11_dev, &dev_attr_humidity);
    device_create_file(dht11_dev, &dev_attr_temperature);

    pr_info("dht11: probe done. gpio=%d\n", dht11_gpio);
    return 0;
}

static int dht11_remove(struct platform_device *pdev)
{
    device_remove_file(dht11_dev, &dev_attr_humidity);
    device_remove_file(dht11_dev, &dev_attr_temperature);
    misc_deregister(&dht11_miscdev);
    pr_info("dht11: removed\n");
    return 0;
}

static const struct of_device_id dht11_of_match[] = {
    { .compatible = "Amiya,mydht11" },
    {},
};
MODULE_DEVICE_TABLE(of, dht11_of_match);

static struct platform_driver dht11_driver = {
    .driver = {
        .name = "100ask_dht11",
        .of_match_table = dht11_of_match,
    },
    .probe = dht11_probe,
    .remove = dht11_remove,
};

module_platform_driver(dht11_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Your Name");
MODULE_DESCRIPTION("DHT11 Temperature and Humidity Sensor Driver");
