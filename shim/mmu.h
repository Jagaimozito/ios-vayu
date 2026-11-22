#pragma once
#include <stdint.h>

#define FB_PHYS	0x9c000000UL

struct mmu_info {
	uint64_t img_lo, img_hi, ttbr;
	uint64_t sctlr_before, sctlr_after;
	int n_l3;
};

int mmu_enable(struct mmu_info *info);
uint64_t mmu_probe(uintptr_t va);
/* Clean + invalidate our image from the D-cache and turn the MMU and caches off again
 * (identity map, so execution continues). Everything after it runs as with the MMU never on. */
void mmu_disable(void);
