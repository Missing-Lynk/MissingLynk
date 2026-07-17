/**
 * @file board.h
 * @brief Device-identity gate: does the running unit match the image's target_device?
 */
#ifndef MLFLASH_BOARD_H
#define MLFLASH_BOARD_H

/**
 * @brief Compare the manifest's target_device to the device's own product id.
 *
 * The product id is sdk_version.json's "product_version" (e.g. "P1_GND_VR04"), which mlimg.py
 * stamps verbatim into target_device - so the match is a plain string compare with no per-product
 * logic. -1 (undeterminable) covers the open slot B, which carries no sdk_version.json.
 *
 * @return 1 = match, 0 = clear mismatch, -1 = product id could not be determined.
 */
int board_matches(const char *manifest_device);

#endif
