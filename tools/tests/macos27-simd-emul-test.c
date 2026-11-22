/* Run on an AArch64 CPU implementing SHA3/SHA512/FHM/FRINTTS (for example an
 * Apple M1). The test runs each encoding with fixed vector registers and checks
 * results against scalar C reference formulas or exactly representable values. */
#include <arm_neon.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
static uint64_t ror(uint64_t x,unsigned n){return(x>>n)|(x<<(64-n));}
static uint64_t B0(uint64_t x){return ror(x,28)^ror(x,34)^ror(x,39);}
static uint64_t B1(uint64_t x){return ror(x,14)^ror(x,18)^ror(x,41);}
static uint64_t s0(uint64_t x){return ror(x,1)^ror(x,8)^(x>>7);}
static uint64_t s1(uint64_t x){return ror(x,19)^ror(x,61)^(x>>6);}
#define TEST4(inst,label,w0,w1) do { \
 uint64_t out[2]; \
 __asm__ volatile("ldr q0,[%1]\nldr q1,[%2]\nldr q2,[%3]\nldr q3,[%4]\n.inst " #inst "\nstr q0,[%0]" \
   ::"r"(out),"r"(a),"r"(b),"r"(c),"r"(e):"v0","v1","v2","v3","memory"); \
 assert(out[0]==(w0)&&out[1]==(w1)); puts(label " ok"); \
} while(0)
#define TEST3(inst,label,w0,w1) TEST4(inst,label,w0,w1)
int main(void){
 const uint64_t a[2]={0x0123456789abcdefULL,0xfedcba9876543210ULL};
 const uint64_t b[2]={0x0f0f0f0f0f0f0f0fULL,0xaaaaaaaa55555555ULL};
 const uint64_t c[2]={0x33333333ccccccccULL,0x0123456789abcdefULL};
 const uint64_t e[2]={0x55555555aaaaaaaaULL,0xdeadbeefcafef00dULL};
 TEST4(0xce020c20,"EOR3",b[0]^c[0]^e[0],b[1]^c[1]^e[1]);
 TEST4(0xce220c20,"BCAX",b[0]^(c[0]&~e[0]),b[1]^(c[1]&~e[1]));
 TEST4(0xce628c20,"RAX1",b[0]+ror(c[0],1),b[1]+ror(c[1],1));
 TEST4(0xce823420,"XAR #13",ror(b[0]^c[0],13),ror(b[1]^c[1],13));
 TEST3(0xcec08020,"SHA512SU0",a[0]+s0(a[1]),a[1]+s0(b[0]));
 TEST3(0xce628820,"SHA512SU1",a[0]+s1(b[0])+c[0],a[1]+s1(b[1])+c[1]);
 uint64_t t=a[1]+B1(c[1])+((c[1]&b[0])^(~c[1]&b[1]));
 TEST3(0xce628020,"SHA512H",a[0]+B1(t+c[0])+(((t+c[0])&c[1])^(~(t+c[0])&b[0])),t);
 t=a[1]+B0(c[0])+((b[0]&c[1])|((b[0]|c[1])&c[0]));
 TEST3(0xce628420,"SHA512H2",a[0]+B0(t)+((t&c[0])|((t|c[0])&c[1])),t);
 /* FHM operands below are binary16 integers; refs are scalar multiply-add/sub. */
 {float x[4]={4,4,0,0};uint16_t n[8]={0x3c00,0x4000,0,0},m[8]={0x4000,0x4200,0,0};float out[4];
  __asm__ volatile("ldr q0,[%1]\nldr q1,[%2]\nldr q2,[%3]\n.inst 0x0e22ec20\nstr q0,[%0]"::"r"(out),"r"(x),"r"(n),"r"(m):"v0","v1","v2","memory");assert(out[0]==6&&out[1]==10);puts("FMLAL ok");}
 {float x[4]={20,20,0,0};uint16_t n[8]={0,0,0x4200,0x4400},m[8]={0,0,0x4400,0x4500};float out[4];
  __asm__ volatile("ldr q0,[%1]\nldr q1,[%2]\nldr q2,[%3]\n.inst 0x2e22cc20\nstr q0,[%0]"::"r"(out),"r"(x),"r"(n),"r"(m):"v0","v1","v2","memory");assert(out[0]==32&&out[1]==40);puts("FMLAL2 ok");}
 {float x[4]={20,20,0,0};uint16_t n[8]={0x3c00,0x4000},m[8]={0x4000,0x4200};float out[4];
  __asm__ volatile("ldr q0,[%1]\nldr q1,[%2]\nldr q2,[%3]\n.inst 0x0ea2ec20\nstr q0,[%0]"::"r"(out),"r"(x),"r"(n),"r"(m):"v0","v1","v2","memory");assert(out[0]==18&&out[1]==14);puts("FMLSL ok");}
 {float x[4]={40,40,0,0};uint16_t n[8]={0,0,0x4200,0x4400},m[8]={0,0,0x4400,0x4500};float out[4];
  __asm__ volatile("ldr q0,[%1]\nldr q1,[%2]\nldr q2,[%3]\n.inst 0x2ea2cc20\nstr q0,[%0]"::"r"(out),"r"(x),"r"(n),"r"(m):"v0","v1","v2","memory");assert(out[0]==28&&out[1]==20);puts("FMLSL2 ok");}
 {float x[4]={5,5,0,0};uint16_t n[8]={0x3c00,0x4000},m[8]={0,0,0x4400};float out[4];
  __asm__ volatile("ldr q0,[%1]\nldr q1,[%2]\nldr q2,[%3]\n.inst 0x0fa20020\nstr q0,[%0]"::"r"(out),"r"(x),"r"(n),"r"(m):"v0","v1","v2","memory");assert(out[0]==9&&out[1]==13);puts("FMLAL by-element ok");}
 {float x[4]={20,20,0,0};uint16_t n[8]={0,0,0x4200,0x4400},m[8]={0,0,0x4400};float out[4];
  __asm__ volatile("ldr q0,[%1]\nldr q1,[%2]\nldr q2,[%3]\n.inst 0x2fa28020\nstr q0,[%0]"::"r"(out),"r"(x),"r"(n),"r"(m):"v0","v1","v2","memory");assert(out[0]==32&&out[1]==36);puts("FMLAL2 by-element ok");}
 {float x[4]={20,20,0,0};uint16_t n[8]={0x3c00,0x4000},m[8]={0,0,0x4400};float out[4];
  __asm__ volatile("ldr q0,[%1]\nldr q1,[%2]\nldr q2,[%3]\n.inst 0x0fa24020\nstr q0,[%0]"::"r"(out),"r"(x),"r"(n),"r"(m):"v0","v1","v2","memory");assert(out[0]==16&&out[1]==12);puts("FMLSL by-element ok");}
 {float x[4]={30,30,0,0};uint16_t n[8]={0,0,0x4200,0x4400},m[8]={0,0,0x4200};float out[4];
  __asm__ volatile("ldr q0,[%1]\nldr q1,[%2]\nldr q2,[%3]\n.inst 0x2fa2c020\nstr q0,[%0]"::"r"(out),"r"(x),"r"(n),"r"(m):"v0","v1","v2","memory");assert(out[0]==21&&out[1]==18);puts("FMLSL2 by-element ok");}
 {float32x2_t x={3.75f,-2.75f},z;__asm__ volatile("frint32z %0.2s,%1.2s":"=w"(z):"w"(x));assert(z[0]==3&&z[1]==-2);__asm__ volatile("frint32x %0.2s,%1.2s":"=w"(z):"w"(x));assert(z[0]==4&&z[1]==-3);puts("FRINT32Z/X vector ok");}
 {float64x2_t x={3.75,-2.75},z;__asm__ volatile("frint64z %0.2d,%1.2d":"=w"(z):"w"(x));assert(z[0]==3&&z[1]==-2);__asm__ volatile("frint64x %0.2d,%1.2d":"=w"(z):"w"(x));assert(z[0]==4&&z[1]==-3);puts("FRINT64Z/X vector ok");}
 {float x=3.75f,z;double y=-2.75,w;__asm__ volatile("frint32z %s0,%s1":"=w"(z):"w"(x));assert(z==3);__asm__ volatile("frint32x %s0,%s1":"=w"(z):"w"(x));assert(z==4);__asm__ volatile("frint64z %d0,%d1":"=w"(w):"w"(y));assert(w==-2);__asm__ volatile("frint64x %d0,%d1":"=w"(w):"w"(y));assert(w==-3);puts("FRINT32/64Z/X scalar ok");}
 puts("All SHA3/SHA512/FHM/FRINTTS checks passed");return 0;
}
