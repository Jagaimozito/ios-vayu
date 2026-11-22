/*
 * Boot-menu touch (guacamole, 2026-11-22): the Samsung S6SY761 at 0x48 on QUP wrapper 2 SE0 (qupv3_se17),
 * polled through the SE's FIFO I2C. A port of the kernel's bsd/dev/sweet_touch.c (clocks, SE setup, IC power-up
 * and event decoding as there) and of the L17A vote from bsd/dev/sweet_rpmh.c, for the shim: no threads, no
 * printf, every wait bounded. Any failure turns touch off for this boot; the keys keep working.
 *
 * touch_begin() only starts the IC (reset held, L17A 3.008 V voted, 1.8 V switch on, out of reset) and returns:
 * the IC takes ~300 ms to start, and touch_poll() says -1 until then, so the menu is not delayed. The kernel
 * repeats the whole power-up later (reset low, vote, 300 ms), and finds the engine idle as it expects.
 */
#include <stdint.h>
#include "touch.h"

#define rsr(r) ({ uint64_t _v; __asm__ volatile("mrs %0, " r : "=r"(_v)); _v; })
static uint64_t now(void) { __asm__ volatile("isb" ::: "memory"); return rsr("cntpct_el0"); }
static uint64_t us_ticks(unsigned us) { return rsr("cntfrq_el0") / 1000000 * us; }
static void udelay(unsigned us) { uint64_t e = now() + us_ticks(us); while (now() < e) ; }

static inline uint32_t rd(uintptr_t b, uint32_t off)
{
	uint32_t v = *(volatile uint32_t *)(b + off);
	__asm__ volatile("dmb oshld" ::: "memory");
	return v;
}
static inline void wr(uintptr_t b, uint32_t off, uint32_t v)
{
	__asm__ volatile("dmb oshst" ::: "memory");
	*(volatile uint32_t *)(b + off) = v;
	__asm__ volatile("dsb osh" ::: "memory");
}
static int wait_clear(uintptr_t b, uint32_t off, uint32_t mask)
{
	for (unsigned i = 0; i < 5000; i++) {
		if (!(rd(b, off) & mask))
			return 1;
		udelay(1);
	}
	return 0;
}

/* ---- L17A (touch 3.0 V) through RPMh, as sweet_rpmh.c ---- */
#define RH_RSC		0x18220000UL
#define RH_TCS		0x18220d00UL
#define RH_TCS_SIZE	0x3000u
#define RH_DICT		0x0c3f000cUL
#define RH_DRV		2u
#define RH_ACTIVE_N	2u
#define RH_NORMAL_N	8u
#define RH_STRIDE	0x2a0u
#define RH_CMD_STRIDE	0x14u
#define RH_IRQ_EN	0x00u
#define RH_IRQ_STATUS	0x04u
#define RH_IRQ_CLEAR	0x08u
#define RH_WAIT		0x10u
#define RH_CONTROL	0x14u
#define RH_STATUS	0x18u
#define RH_ENABLE	0x1cu
#define RH_MSGID	0x30u
#define RH_ADDR		0x34u
#define RH_DATA		0x38u
#define RH_CMD_STATUS	0x3cu
#define RH_AMC_EN	(1u << 16)
#define RH_TRIGGER	(1u << 24)
#define RH_ISSUED	(1u << 8)
#define RH_COMPLETE	(1u << 16)
#define RH_WRITE_ACK	(8u | (1u << 8) | (1u << 16))
#define RH_DB_MAGIC	0x0c0330dbu
#define RH_DB_HEADER	144u
#define RH_DB_ENTRY	24u
#define RH_VRM		4u

static uintptr_t rh_db;
static uint32_t rh_db_size;
static unsigned rh_ncpt;

static int rh_sync(uint32_t off, uint32_t v)
{
	wr(RH_TCS, off, v);
	for (unsigned i = 0; i < 1000; i++) {
		if (rd(RH_TCS, off) == v)
			return 1;
		udelay(1);
	}
	return 0;
}
static uint16_t rh_db16(uint32_t off) { return (uint16_t)(rd(rh_db, off & ~3u) >> (8u * (off & 3u))); }
static int rh_range(uint32_t off, uint32_t size) { return off <= rh_db_size && size <= rh_db_size - off; }

static int rh_map(void)
{
	uint32_t id = rd(RH_RSC, 0), solver = rd(RH_RSC, 4), config = rd(RH_RSC, 0x0c);
	unsigned major = (id >> 16) & 0xff, count = (config >> (6u * RH_DRV)) & 0x3f;
	rh_ncpt = (config >> 27) & 0x1f;
	if ((major != 1 && major != 2) || config == 0xffffffffu || solver == 0xffffffffu || count < RH_NORMAL_N ||
	    count > RH_TCS_SIZE / RH_STRIDE || rh_ncpt < 3 || rh_ncpt > 16)
		return -1;
	uint32_t pa = rd(RH_DICT, 0), size = rd(RH_DICT, 4);
	if (pa < 0x80000000u || (pa & 3) || (size & 3) || size < RH_DB_HEADER || size > 0x100000u)
		return -1;
	rh_db = pa;
	rh_db_size = size;
	if (rd(rh_db, 4) != RH_DB_MAGIC || rd(rh_db, 0) != 1 || (rd(rh_db, 140) & 1))
		return -1;
	return 0;
}

static int rh_lookup(const char *res, uint32_t *address)
{
	uint32_t key[2] = {0, 0};
	for (unsigned i = 0; i < 8 && res[i]; i++)
		key[i / 4] |= (uint32_t)(uint8_t)res[i] << (8u * (i % 4));
	unsigned matches = 0, differing = 0;
	uint32_t first = 0;
	for (unsigned i = 0; i < 8; i++) {
		uint32_t h = 8u + 16u * i;
		unsigned slave = rh_db16(h);
		if (!slave)
			break;
		uint32_t entries = RH_DB_HEADER + rh_db16(h + 2), aux = RH_DB_HEADER + rh_db16(h + 4);
		unsigned count = rh_db16(h + 6);
		if (slave < 3 || slave > 5 || (entries & 3) || !rh_range(entries, count * RH_DB_ENTRY) || !rh_range(aux, 0))
			return -1;
		for (unsigned j = 0; j < count; j++) {
			uint32_t e = entries + RH_DB_ENTRY * j;
			if (rd(rh_db, e) != key[0] || rd(rh_db, e + 4) != key[1])
				continue;
			uint32_t addr = rd(rh_db, e + 16);
			if (slave != RH_VRM || (addr >> 16) != slave || (addr & 15))
				return -1;
			if (matches && addr != first)
				differing++;
			if (!matches)
				first = addr;
			matches++;
		}
	}
	if (!matches || differing)
		return -1;
	*address = first;
	return 0;
}

static int rh_free(unsigned t)
{
	uint32_t b = t * RH_STRIDE;
	return rd(RH_TCS, b + RH_STATUS) != 0 && rd(RH_TCS, b + RH_STATUS) != 0xffffffffu &&
	       rd(RH_TCS, b + RH_CONTROL) == 0 && rd(RH_TCS, b + RH_ENABLE) == 0 && rd(RH_TCS, b + RH_WAIT) == 0 &&
	       !(rd(RH_TCS, RH_IRQ_STATUS) & (1u << t));
}

/* L17A: 3008 mV, HPM, enable (sweet_rpmh.c rh_send). */
static int rh_l17a(void)
{
	uint32_t address;
	if (rh_map() || rh_lookup("ldoa17", &address))
		return -1;
	static const uint32_t offs[3] = {0, 8, 4};
	const uint32_t vals[3] = {3008, 7, 1};
	const unsigned n = 3;
	int chosen = -1;
	for (unsigned t = 0; t < RH_ACTIVE_N; t++) {
		uint32_t b = t * RH_STRIDE, en = rd(RH_TCS, b + RH_ENABLE);
		if (en & ~((1u << rh_ncpt) - 1u))
			return -1;
		for (unsigned c = 0; c < rh_ncpt; c++)
			if ((en & (1u << c)) && (rd(RH_TCS, b + RH_ADDR + c * RH_CMD_STRIDE) & ~15u) == address)
				return -1;
		if (chosen < 0 && rh_free(t))
			chosen = (int)t;
	}
	if (chosen < 0)
		return -1;
	unsigned t = (unsigned)chosen;
	uint32_t b = t * RH_STRIDE, bit = 1u << t, irq_en = rd(RH_TCS, RH_IRQ_EN);
	if (irq_en == 0xffffffffu || !rh_sync(RH_IRQ_EN, irq_en & ~bit))
		return -1;
	for (unsigned c = 0; c < n; c++) {
		uint32_t cmd = b + c * RH_CMD_STRIDE;
		if (!rh_sync(cmd + RH_MSGID, RH_WRITE_ACK) || !rh_sync(cmd + RH_ADDR, address + offs[c]) ||
		    !rh_sync(cmd + RH_DATA, vals[c]))
			return -1;
	}
	uint32_t mask = (1u << n) - 1u;
	if (!rh_sync(b + RH_WAIT, mask) || !rh_sync(b + RH_ENABLE, mask) || !rh_sync(b + RH_CONTROL, 0) ||
	    !rh_sync(b + RH_CONTROL, RH_AMC_EN))
		return -1;
	wr(RH_TCS, b + RH_CONTROL, RH_AMC_EN | RH_TRIGGER);
	int done = 0, progress = 0;
	for (unsigned us = 0; us < 100000; us++) {
		uint32_t irq = rd(RH_TCS, RH_IRQ_STATUS), idle = rd(RH_TCS, b + RH_STATUS);
		int complete = 1;
		for (unsigned c = 0; c < n; c++) {
			uint32_t s = rd(RH_TCS, b + RH_CMD_STATUS + c * RH_CMD_STRIDE);
			complete &= s != 0xffffffffu && (s & (RH_ISSUED | RH_COMPLETE)) == (RH_ISSUED | RH_COMPLETE);
		}
		progress |= idle == 0 || !complete;
		if (idle && idle != 0xffffffffu && irq != 0xffffffffu && ((irq & bit) || progress) && complete) {
			done = 1;
			break;
		}
		udelay(1);
	}
	if (!done)
		return -1;	/* the TCS stays as it is, IRQ masked: as the kernel does */
	if (!rh_sync(b + RH_CONTROL, RH_AMC_EN) || !rh_sync(b + RH_CONTROL, 0) || !rh_sync(b + RH_ENABLE, 0) ||
	    !rh_sync(b + RH_WAIT, 0))
		return -1;
	wr(RH_TCS, RH_IRQ_CLEAR, bit);
	if ((rd(RH_TCS, RH_IRQ_STATUS) & bit) || !rh_sync(RH_IRQ_EN, (rd(RH_TCS, RH_IRQ_EN) & ~bit) | (irq_en & bit)))
		return -1;
	return 0;
}

/* ---- the SE (sweet_touch.c) ---- */
#define SE		0x00c80000UL
#define GCC		0x00100000UL
#define TLMM_S		0x03d00000UL
#define GCC_VOTE	0x52014u
#define GCC_MASK	0x1fu
#define RCG		0x1e148u
#define GPIO_CFG(n)	((uint32_t)(n) * 0x1000u)
#define GPIO_IO(n)	(GPIO_CFG(n) + 4u)
#define TP_ADDR		0x48u
#define TP_RST		54u
#define TP_IRQ		122u
#define TP_1V8		119u
#define TP_SDA		55u
#define TP_SCL		56u
#define TP_W		1440
#define TP_H		3120
#define SY_SENSE_ON	0x10u
#define SY_TOUCH_FUNC	0x30u
#define SY_BOOT_STATUS	0x55u
#define SY_READ_ONE	0x60u
#define SY_READ_ALL	0x61u
#define SY_CLEAR_STACK	0x62u
#define SY_EVENT	8u
#define SY_MORE_MAX	10u
#define MAXT		10u

#define SE_STATUS	0x040u
#define SE_MCLK		0x048u
#define SE_FW		0x068u
#define SE_CLK_SEL	0x07cu
#define SE_DMA		0x258u
#define SE_TX_LEN	0x26cu
#define SE_RX_LEN	0x270u
#define SE_SCL		0x278u
#define SE_CMD		0x600u
#define SE_CTRL		0x604u
#define SE_IRQ		0x610u
#define SE_IRQ_EN	0x614u
#define SE_IRQ_CLR	0x618u
#define SE_TX		0x700u
#define SE_RX		0x780u
#define SE_TX_COUNT	0x800u
#define SE_RX_COUNT	0x804u
#define SE_HW_TX	0xe24u
#define SE_HW_RX	0xe28u
#define SE_TX_WM	0x80cu
#define SE_RX_WM_IRQ	(1u << 26)
#define SE_RX_LAST	(1u << 27)
#define SE_TX_WM_IRQ	(1u << 30)
#define SE_DONE		(1u << 0)
#define SE_NACK		(1u << 10)
#define SE_ERRORS	(0x3eu | (1u << 9) | (1u << 10) | (1u << 12) | (1u << 13) | (3u << 24) | (3u << 28))
#define SE_EVENTS	(SE_DONE | SE_ERRORS | SE_RX_WM_IRQ | SE_RX_LAST | SE_TX_WM_IRQ)
#define SE_PACK0	0x0007f8feu
#define SE_PACK1	0x000ffefeu

enum { T_OFF, T_STARTING, T_ON, T_DEAD };
static int state = T_OFF;
static uint64_t ready_at;
static unsigned clk_sel, sent, got;
static uint32_t active;
static int tx_[MAXT], ty_[MAXT];

static void gpio(unsigned pin, unsigned mux, unsigned pull, unsigned drive, int out, int high)
{
	uint32_t off = GPIO_CFG(pin), cfg = rd(TLMM_S, off);
	if (out)
		wr(TLMM_S, GPIO_IO(pin), (rd(TLMM_S, GPIO_IO(pin)) & ~2u) | (high ? 2u : 0u));
	cfg &= ~0x3ffu;
	cfg |= (mux << 2) | pull | (drive << 6) | (out ? 0x200u : 0u);
	wr(TLMM_S, off, cfg);
}

static int clocks(void)
{
	wr(GCC, GCC_VOTE, rd(GCC, GCC_VOTE) | GCC_MASK);
	uint32_t dfs = rd(GCC, RCG + 0x14), cfg = rd(GCC, RCG + 4);
	clk_sel = 0;
	if (dfs & 1) {
		int level = -1;
		for (unsigned l = 0; l < 8; l++)
			if (level < 0 && (rd(GCC, RCG + 0x1c + 4 * l) & 0x371fu) == 1u)
				level = (int)l;
		if (level < 0)
			return -1;
		clk_sel = (unsigned)level;
	} else {
		cfg = (cfg & ~(0x371fu | (1u << 20))) | 1u;
		wr(GCC, RCG + 4, cfg);
		wr(GCC, RCG, rd(GCC, RCG) | 1u);
		if (!wait_clear(GCC, RCG, 1u))
			return -1;
	}
	static const uint32_t branches[3] = {0x1e004, 0x1e008, 0x1e144};
	for (unsigned i = 0; i < 3; i++) {
		if (wait_clear(GCC, branches[i], 1u << 31))
			continue;
		if (branches[i] == 0x1e008u && (rd(GCC, branches[i]) & 2u))
			continue;	/* S_AHB in hardware gating mode */
		return -1;
	}
	return 0;
}

static int se_init(void)
{
	uint32_t fw = rd(SE, SE_FW), tx = rd(SE, SE_HW_TX), rx = rd(SE, SE_HW_RX);
	if (((fw >> 8) & 0xff) != 3u || (rd(SE, 0x64) & 1u) || ((tx >> 24) & 0x3f) != 32u || ((rx >> 24) & 0x3f) != 32u ||
	    ((tx >> 16) & 0x3f) < 2u || ((rx >> 16) & 0x3f) < 2u)
		return -1;	/* no ABL-loaded I2C firmware */
	if (rd(SE, SE_STATUS) & 0x1001u)
		return -1;
	wr(SE, 0xe18, 0);
	wr(SE, 0xe1c, 0);
	wr(SE, 0x644, 0);
	wr(SE, SE_IRQ_CLR, 0xffffffffu);
	wr(SE, 0x648, 0xffffffffu);
	wr(SE, SE_DMA, 0);
	wr(SE, 0x28, rd(SE, 0x28) | 0x7fu);
	wr(SE, 0xe30, rd(SE, 0xe30) | 0x0fu);
	wr(SE, 0x24, 0x7f);
	wr(SE, 0x20, 1);
	wr(SE, SE_CLK_SEL, clk_sel);
	wr(SE, SE_MCLK, (2u << 4) | 1u);		/* 400 kHz from 19.2 MHz */
	wr(SE, SE_SCL, (5u << 20) | (12u << 10) | 24u);
	wr(SE, 0x254, 0);
	wr(SE, 0x260, SE_PACK0);
	wr(SE, 0x264, SE_PACK1);
	wr(SE, 0x284, SE_PACK0);
	wr(SE, 0x288, SE_PACK1);
	wr(SE, SE_TX_WM, 0);
	wr(SE, 0x810, 0);
	wr(SE, 0x814, ((rx >> 16) & 0x3f) - 1u);
	wr(SE, SE_IRQ_EN, SE_EVENTS);
	if (rd(SE, 0x260) != SE_PACK0 || rd(SE, 0x264) != SE_PACK1 || rd(SE, 0x284) != SE_PACK0 ||
	    rd(SE, 0x288) != SE_PACK1 || rd(SE, 0x254) != 0)
		return -1;
	if ((rd(SE, SE_TX_COUNT) & 0xfffffffu) || (rd(SE, SE_RX_COUNT) & 0x1ffffffu))
		return -1;
	return 0;
}

static void se_abort(void)
{
	wr(SE, SE_CTRL, 2);
	int done = 0;
	for (unsigned i = 0; i < 5000; i++) {
		if (rd(SE, SE_IRQ) & (1u << 5)) {
			done = 1;
			break;
		}
		udelay(1);
	}
	if (!done || !wait_clear(SE, SE_STATUS, 1u))
		state = T_DEAD;
	for (unsigned i = 0; i < 64 && (rd(SE, SE_RX_COUNT) & 0x1ffffffu); i++)
		(void)rd(SE, SE_RX);
	wr(SE, SE_IRQ_CLR, 0xffffffffu);
	if (rd(SE, SE_TX_COUNT) & 0xfffffffu)
		state = T_DEAD;
}

/* One FIFO message, TX <= 3 bytes or RX <= 90 (sweet_touch.c touch_msg_run). 0 = ok. */
static int msg(const uint8_t *txb, unsigned nt, uint8_t *rxb, unsigned nr, int stretch)
{
	if (state == T_DEAD || nt > 3 || nr > 90 || (nt && nr) || (!nt && !nr))
		return -1;
	if (!wait_clear(SE, SE_STATUS, 1u)) {
		state = T_DEAD;
		return -1;
	}
	sent = got = 0;
	wr(SE, SE_IRQ_CLR, 0xffffffffu);
	wr(SE, SE_TX_WM, nt ? 1u : 0u);
	wr(SE, nr ? SE_RX_LEN : SE_TX_LEN, nr ? nr : nt);
	wr(SE, SE_CMD, ((nr ? 2u : 1u) << 27) | ((uint32_t)TP_ADDR << 9) | (stretch ? 4u : 0u));
	for (unsigned i = 0; i < 20000; i++) {
		uint32_t irq = rd(SE, SE_IRQ);
		if (irq & SE_ERRORS) {
			for (unsigned j = 0; j < 5000 && !(irq & SE_DONE); j++) {
				udelay(1);
				irq = rd(SE, SE_IRQ);
			}
			if ((irq & SE_DONE) && !(rd(SE, SE_STATUS) & 1u) && !(rd(SE, SE_TX_COUNT) & 0xfffffffu) &&
			    !(rd(SE, SE_RX_COUNT) & 0x1ffffffu)) {
				wr(SE, SE_IRQ_CLR, irq);
				return -1;
			}
			break;
		}
		if (nt && !sent && (irq & SE_TX_WM_IRQ)) {
			uint32_t word = 0;
			for (unsigned j = 0; j < nt; j++)
				word |= (uint32_t)txb[j] << (8u * j);
			wr(SE, SE_TX, word);
			sent = nt;
			wr(SE, SE_TX_WM, 0);
		}
		uint32_t count = rd(SE, SE_RX_COUNT) & 0x1ffffffu;
		if (count > 64 || count > (nr - got + 3u) / 4u)
			break;
		while (count--) {
			uint32_t word = rd(SE, SE_RX);
			for (unsigned j = 0; j < 4 && got < nr; j++)
				rxb[got++] = (uint8_t)(word >> (8u * j));
		}
		if (irq & SE_DONE) {
			irq = rd(SE, SE_IRQ);
			if (irq & SE_ERRORS)
				continue;
			wr(SE, SE_IRQ_CLR, irq);
			if (got == nr && sent == nt)
				return 0;
			break;
		}
		wr(SE, SE_IRQ_CLR, irq & (SE_RX_WM_IRQ | SE_RX_LAST | SE_TX_WM_IRQ));
		udelay(1);
	}
	se_abort();
	return -1;
}

static int ic_read(uint8_t reg, uint8_t *buf, unsigned len)
{
	if (msg(&reg, 1, 0, 0, 1))
		return -1;
	return msg(0, 0, buf, len, 0);
}

static int ic_write(const uint8_t *b, unsigned n) { return msg(b, n, 0, 0, 0); }

int touch_begin(void)
{
	if (state != T_OFF)
		return state == T_DEAD ? -1 : 0;
	state = T_DEAD;
	if (clocks() || se_init())
		return -1;
	gpio(TP_IRQ, 0, 0, 3, 0, 0);		/* input, no bias, 8 mA */
	gpio(TP_RST, 0, 0, 3, 1, 0);		/* reset held (low) */
	if (rh_l17a())
		return -1;
	gpio(TP_1V8, 0, 3, 3, 0, 0);		/* 1.8 V load switch: pull-up = on */
	udelay(10000);
	gpio(TP_SDA, 1, 0, 0, 0, 0);		/* qup17 */
	gpio(TP_SCL, 1, 0, 0, 0, 0);
	gpio(TP_RST, 0, 0, 3, 1, 1);		/* out of reset */
	ready_at = now() + us_ticks(300000);	/* as the kernel (Linux waits 140 ms) */
	state = T_STARTING;
	return 0;
}

static int ic_start(void)
{
	uint8_t bs = 0;
	if (ic_read(SY_BOOT_STATUS, &bs, 1) || bs != 0x20u)
		return -1;	/* not in application mode */
	const uint8_t func[3] = {SY_TOUCH_FUNC, 0x01, 0x00};
	const uint8_t on = SY_SENSE_ON;
	if (ic_write(func, 3) || ic_write(&on, 1))
		return -1;
	active = 0;
	return 0;
}

/* Events since the last read -> the contact set (sweet_touch.c touch_s6sy / touch_event). */
static int ic_events(void)
{
	uint8_t buf[SY_EVENT * (1u + SY_MORE_MAX)];
	if (ic_read(SY_READ_ONE, buf, SY_EVENT))
		return -1;
	if (buf[0] == 0)
		return 0;
	unsigned left = buf[7] & 0x3fu, n = 1;
	if (left > SY_MORE_MAX) {
		const uint8_t clr = SY_CLEAR_STACK;
		(void)ic_write(&clr, 1);
		active = 0;
		return -1;
	}
	if (left) {
		if (ic_read(SY_READ_ALL, buf + SY_EVENT, left * SY_EVENT))
			return -1;
		n += left;
	}
	for (unsigned i = 0; i < n; i++) {
		const uint8_t *e = buf + i * SY_EVENT;
		if (e[0] == 0)
			break;
		if (e[0] & 3u)
			continue;			/* status / info event */
		unsigned tid = (e[0] & 0x3cu) >> 2;
		if (tid == 0 || tid > MAXT)
			continue;
		tid--;
		unsigned st = e[0] >> 6;
		if (st == 3u) {
			active &= ~(1u << tid);
		} else if (st == 1u || st == 2u) {
			unsigned px = ((unsigned)e[1] << 4) | (e[3] >> 4), py = ((unsigned)e[2] << 4) | (e[3] & 15u);
			if (px >= TP_W || py >= TP_H)
				continue;
			active |= 1u << tid;
			tx_[tid] = (int)px;
			ty_[tid] = (int)py;
		}
	}
	return 0;
}

int touch_poll(int *x, int *y)
{
	static unsigned errors;
	if (state == T_STARTING) {
		if (now() < ready_at)
			return -1;
		if (ic_start()) {
			state = T_DEAD;
			return -1;
		}
		state = T_ON;
	}
	if (state != T_ON)
		return -1;
	if (ic_events()) {
		if (++errors >= 50)
			state = T_DEAD;		/* persistent bad reads: keys only */
		if (errors >= 10)
			active = 0;
		return active ? 1 : 0;
	}
	errors = 0;
	if (!active)
		return 0;
	for (unsigned i = 0; i < MAXT; i++)
		if (active & (1u << i)) {
			*x = tx_[i];
			*y = ty_[i];
			return 1;
		}
	return 0;
}

void touch_end(void)
{
	if (state == T_OFF)
		return;
	if (rd(SE, SE_STATUS) & 1u)
		se_abort();
	for (unsigned i = 0; i < 64 && (rd(SE, SE_RX_COUNT) & 0x1ffffffu); i++)
		(void)rd(SE, SE_RX);
	wr(SE, SE_IRQ_CLR, 0xffffffffu);
	state = T_DEAD;
}
