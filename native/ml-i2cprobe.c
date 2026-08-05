/**
 * @file ml-i2cprobe.c
 * @brief Read and write camera-sensor registers that use a 16-bit register address.
 *
 * The NT99235 (and the SmartSens alternates the vendor board config lists) address their registers
 * with 16 bits and carry 8-bit values. busybox i2cget cannot express that: it only emits an 8-bit
 * register address. This tool issues a proper repeated-start transaction through the I2C_RDWR
 * ioctl, so a read is one address-write plus one data-read with no STOP in between.
 *
 * Build: see build.sh (static, aarch64).
 * Use:   ml-i2cprobe <bus> <chip> <reg>            read one register
 *        ml-i2cprobe <bus> <chip> <reg> <value>    write one register
 *        ml-i2cprobe <bus> <chip> <reg> -n <count> read count consecutive registers
 *
 * Example (NT99235 chip id on the air unit): ml-i2cprobe 0 0x1a 0x3000 -n 2
 */
#include <fcntl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/** Largest run a single invocation will read, to keep output bounded. */
#define MAX_READ_COUNT 256

/**
 * @brief Read one 8-bit value from a 16-bit register address.
 *
 * @param bus_fd           open file descriptor for the /dev/i2c-N bus.
 * @param chip_address     7-bit device address.
 * @param register_address 16-bit register address.
 * @param value_out        receives the register value.
 *
 * @return 0 on success, -1 on failure.
 */
static int read_register(int bus_fd, uint16_t chip_address, uint16_t register_address,
                         uint8_t *value_out)
{
    uint8_t address_bytes[2];
    struct i2c_msg messages[2];
    struct i2c_rdwr_ioctl_data transaction;

    /* Register address goes out big-endian, which is what these sensors expect. */
    address_bytes[0] = (uint8_t)(register_address >> 8);
    address_bytes[1] = (uint8_t)(register_address & 0xff);

    messages[0].addr = chip_address;
    messages[0].flags = 0;
    messages[0].len = sizeof(address_bytes);
    messages[0].buf = address_bytes;

    messages[1].addr = chip_address;
    messages[1].flags = I2C_M_RD;
    messages[1].len = 1;
    messages[1].buf = value_out;

    transaction.msgs = messages;
    transaction.nmsgs = 2;

    if (ioctl(bus_fd, I2C_RDWR, &transaction) < 0) {
        return -1;
    }

    return 0;
}

/**
 * @brief Write one 8-bit value to a 16-bit register address.
 *
 * @param bus_fd           open file descriptor for the /dev/i2c-N bus.
 * @param chip_address     7-bit device address.
 * @param register_address 16-bit register address.
 * @param value            value to write.
 *
 * @return 0 on success, -1 on failure.
 */
static int write_register(int bus_fd, uint16_t chip_address, uint16_t register_address,
                          uint8_t value)
{
    uint8_t payload[3];
    struct i2c_msg message;
    struct i2c_rdwr_ioctl_data transaction;

    payload[0] = (uint8_t)(register_address >> 8);
    payload[1] = (uint8_t)(register_address & 0xff);
    payload[2] = value;

    message.addr = chip_address;
    message.flags = 0;
    message.len = sizeof(payload);
    message.buf = payload;

    transaction.msgs = &message;
    transaction.nmsgs = 1;

    if (ioctl(bus_fd, I2C_RDWR, &transaction) < 0) {
        return -1;
    }

    return 0;
}

/**
 * @brief Entry point: parse arguments and perform the requested transaction.
 */
int main(int argc, char **argv)
{
    char bus_path[32];
    int bus_fd;
    uint16_t chip_address;
    uint16_t register_address;
    int result = 0;

    if (argc < 4) {
        fprintf(stderr,
                "usage: ml-i2cprobe <bus> <chip> <reg>            read one register\n"
                "       ml-i2cprobe <bus> <chip> <reg> <value>    write one register\n"
                "       ml-i2cprobe <bus> <chip> <reg> -n <count> read count registers\n");
        return 2;
    }

    snprintf(bus_path, sizeof(bus_path), "/dev/i2c-%s", argv[1]);
    chip_address = (uint16_t)strtoul(argv[2], NULL, 0);
    register_address = (uint16_t)strtoul(argv[3], NULL, 0);

    bus_fd = open(bus_path, O_RDWR);
    if (bus_fd < 0) {
        perror("ml-i2cprobe: open bus");
        return 1;
    }

    if (argc >= 6 && strcmp(argv[4], "-n") == 0) {
        unsigned long count = strtoul(argv[5], NULL, 0);
        unsigned long i;

        if (count == 0 || count > MAX_READ_COUNT) {
            fprintf(stderr, "ml-i2cprobe: count must be 1..%d\n", MAX_READ_COUNT);
            close(bus_fd);
            return 2;
        }

        for (i = 0; i < count; i++) {
            uint16_t current = (uint16_t)(register_address + i);
            uint8_t value = 0;

            if (read_register(bus_fd, chip_address, current, &value) != 0) {
                fprintf(stderr, "ml-i2cprobe: read 0x%04x failed\n", current);
                result = 1;
                break;
            }

            printf("0x%04x = 0x%02x\n", current, value);
        }
    } else if (argc >= 5) {
        uint8_t value = (uint8_t)strtoul(argv[4], NULL, 0);

        if (write_register(bus_fd, chip_address, register_address, value) != 0) {
            perror("ml-i2cprobe: write");
            result = 1;
        } else {
            printf("0x%04x <= 0x%02x\n", register_address, value);
        }
    } else {
        uint8_t value = 0;

        if (read_register(bus_fd, chip_address, register_address, &value) != 0) {
            perror("ml-i2cprobe: read");
            result = 1;
        } else {
            printf("0x%04x = 0x%02x\n", register_address, value);
        }
    }

    close(bus_fd);

    return result;
}
