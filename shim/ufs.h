#pragma once
#include <stdint.h>
void test_ufs(void);
/* Boot selector: 0 = success. Blocks are 4 KiB. Reads, except ufs_bootmem_write (one block, see ufs.c). */
int ufs_open(void);
int ufs_find(const char *name, uint8_t *lun, uint32_t *first, uint32_t *last);
uint32_t ufs_read(uint8_t lun, uint32_t lba, uint32_t count, void *buf);
/* Same, plus the unique partition GUID (16 bytes as stored in the GPT entry). */
int ufs_find_guid(const char *name, uint8_t *lun, uint32_t *first, uint32_t *last, uint8_t *guid);
/* The boot menu memory block (4 KiB, unallocated space at the end of LUN 0). 0 = ok. */
int ufs_bootmem_read(void *block);
int ufs_bootmem_write(const void *block);
