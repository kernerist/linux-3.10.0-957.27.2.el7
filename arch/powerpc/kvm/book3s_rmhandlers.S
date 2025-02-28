/*
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License, version 2, as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *
 * Copyright SUSE Linux Products GmbH 2009
 *
 * Authors: Alexander Graf <agraf@suse.de>
 */

#include <asm/ppc_asm.h>
#include <asm/kvm_asm.h>
#include <asm/reg.h>
#include <asm/mmu.h>
#include <asm/page.h>
#include <asm/asm-offsets.h>

#ifdef CONFIG_PPC_BOOK3S_64
#include <asm/exception-64s.h>
#endif

/*****************************************************************************
 *                                                                           *
 *        Real Mode handlers that need to be in low physical memory          *
 *                                                                           *
 ****************************************************************************/

#if defined(CONFIG_PPC_BOOK3S_64)

#if defined(_CALL_ELF) && _CALL_ELF == 2
#define FUNC(name) 		name
#else
#define FUNC(name) 		GLUE(.,name)
#endif

#elif defined(CONFIG_PPC_BOOK3S_32)

#define FUNC(name)		name

#define RFI_TO_KERNEL  RFI
#define RFI_TO_GUEST   RFI

.macro INTERRUPT_TRAMPOLINE intno

.global kvmppc_trampoline_\intno
kvmppc_trampoline_\intno:

	mtspr	SPRN_SPRG_SCRATCH0, r13		/* Save r13 */

	/*
	 * First thing to do is to find out if we're coming
	 * from a KVM guest or a Linux process.
	 *
	 * To distinguish, we check a magic byte in the PACA/current
	 */
	mfspr	r13, SPRN_SPRG_THREAD
	lwz	r13, THREAD_KVM_SVCPU(r13)
	/* PPC32 can have a NULL pointer - let's check for that */
	mtspr   SPRN_SPRG_SCRATCH1, r12		/* Save r12 */
	mfcr	r12
	cmpwi	r13, 0
	bne	1f
2:	mtcr	r12
	mfspr	r12, SPRN_SPRG_SCRATCH1
	mfspr	r13, SPRN_SPRG_SCRATCH0		/* r13 = original r13 */
	b	kvmppc_resume_\intno		/* Get back original handler */

1:	tophys(r13, r13)
	stw	r12, HSTATE_SCRATCH1(r13)
	mfspr	r12, SPRN_SPRG_SCRATCH1
	stw	r12, HSTATE_SCRATCH0(r13)
	lbz	r12, HSTATE_IN_GUEST(r13)
	cmpwi	r12, KVM_GUEST_MODE_NONE
	bne	..kvmppc_handler_hasmagic_\intno
	/* No KVM guest? Then jump back to the Linux handler! */
	lwz	r12, HSTATE_SCRATCH1(r13)
	b	2b

	/* Now we know we're handling a KVM guest */
..kvmppc_handler_hasmagic_\intno:

	/* Should we just skip the faulting instruction? */
	cmpwi	r12, KVM_GUEST_MODE_SKIP
	beq	kvmppc_handler_skip_ins

	/* Let's store which interrupt we're handling */
	li	r12, \intno

	/* Jump into the SLB exit code that goes to the highmem handler */
	b	kvmppc_handler_trampoline_exit

.endm

INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_SYSTEM_RESET
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_MACHINE_CHECK
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_DATA_STORAGE
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_INST_STORAGE
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_EXTERNAL
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_ALIGNMENT
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_PROGRAM
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_FP_UNAVAIL
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_DECREMENTER
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_SYSCALL
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_TRACE
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_PERFMON
INTERRUPT_TRAMPOLINE	BOOK3S_INTERRUPT_ALTIVEC

/*
 * Bring us back to the faulting code, but skip the
 * faulting instruction.
 *
 * This is a generic exit path from the interrupt
 * trampolines above.
 *
 * Input Registers:
 *
 * R12            = free
 * R13            = Shadow VCPU (PACA)
 * HSTATE.SCRATCH0 = guest R12
 * HSTATE.SCRATCH1 = guest CR
 * SPRG_SCRATCH0  = guest R13
 *
 */
kvmppc_handler_skip_ins:

	/* Patch the IP to the next instruction */
	mfsrr0	r12
	addi	r12, r12, 4
	mtsrr0	r12

	/* Clean up all state */
	lwz	r12, HSTATE_SCRATCH1(r13)
	mtcr	r12
	PPC_LL	r12, HSTATE_SCRATCH0(r13)
	GET_SCRATCH0(r13)

	/* And get back into the code */
	RFI_TO_GUEST
#endif

/*
 * Call kvmppc_handler_trampoline_enter in real mode
 *
 * On entry, r4 contains the guest shadow MSR
 * MSR.EE has to be 0 when calling this function
 */
_GLOBAL_TOC(kvmppc_entry_trampoline)
	mfmsr	r5
	LOAD_REG_ADDR(r7, kvmppc_handler_trampoline_enter)
	toreal(r7)

	li	r6, MSR_IR | MSR_DR
	andc	r6, r5, r6	/* Clear DR and IR in MSR value */
	/*
	 * Set EE in HOST_MSR so that it's enabled when we get into our
	 * C exit handler function.
	 */
	ori	r5, r5, MSR_EE
	mtsrr0	r7
	mtsrr1	r6
	RFI_TO_KERNEL

#include "book3s_segment.S"
