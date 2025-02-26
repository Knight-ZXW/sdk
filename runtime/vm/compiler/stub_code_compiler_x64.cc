// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/compiler/runtime_api.h"
#include "vm/globals.h"

// For `AllocateObjectInstr::WillAllocateNewOrRemembered`
#include "vm/compiler/backend/il.h"

#define SHOULD_NOT_INCLUDE_RUNTIME

#include "vm/compiler/backend/locations.h"
#include "vm/compiler/stub_code_compiler.h"

#if defined(TARGET_ARCH_X64) && !defined(DART_PRECOMPILED_RUNTIME)

#include "vm/class_id.h"
#include "vm/code_entry_kind.h"
#include "vm/compiler/assembler/assembler.h"
#include "vm/constants.h"
#include "vm/instructions.h"
#include "vm/static_type_exactness_state.h"
#include "vm/tags.h"

#define __ assembler->

namespace dart {

DEFINE_FLAG(bool, inline_alloc, true, "Inline allocation of objects.");
DEFINE_FLAG(bool,
            use_slow_path,
            false,
            "Set to true for debugging & verifying the slow paths.");
DECLARE_FLAG(bool, precompiled_mode);

namespace compiler {

// Ensures that [RAX] is a new object, if not it will be added to the remembered
// set via a leaf runtime call.
//
// WARNING: This might clobber all registers except for [RAX], [THR] and [FP].
// The caller should simply call LeaveStubFrame() and return.
static void EnsureIsNewOrRemembered(Assembler* assembler,
                                    bool preserve_registers = true) {
  // If the object is not remembered we call a leaf-runtime to add it to the
  // remembered set.
  Label done;
  __ testq(RAX, Immediate(1 << target::ObjectAlignment::kNewObjectBitPosition));
  __ BranchIf(NOT_ZERO, &done);

  if (preserve_registers) {
    __ EnterCallRuntimeFrame(0);
  } else {
    __ ReserveAlignedFrameSpace(0);
  }
  __ movq(CallingConventions::kArg1Reg, RAX);
  __ movq(CallingConventions::kArg2Reg, THR);
  __ CallRuntime(kAddAllocatedObjectToRememberedSetRuntimeEntry, 2);
  if (preserve_registers) {
    __ LeaveCallRuntimeFrame();
  }

  __ Bind(&done);
}

// Input parameters:
//   RSP : points to return address.
//   RSP + 8 : address of last argument in argument array.
//   RSP + 8*R10 : address of first argument in argument array.
//   RSP + 8*R10 + 8 : address of return value.
//   RBX : address of the runtime function to call.
//   R10 : number of arguments to the call.
// Must preserve callee saved registers R12 and R13.
void StubCodeCompiler::GenerateCallToRuntimeStub(Assembler* assembler) {
  const intptr_t thread_offset = target::NativeArguments::thread_offset();
  const intptr_t argc_tag_offset = target::NativeArguments::argc_tag_offset();
  const intptr_t argv_offset = target::NativeArguments::argv_offset();
  const intptr_t retval_offset = target::NativeArguments::retval_offset();

  __ movq(CODE_REG,
          Address(THR, target::Thread::call_to_runtime_stub_offset()));
  __ EnterStubFrame();

  // Save exit frame information to enable stack walking as we are about
  // to transition to Dart VM C++ code.
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()), RBP);

#if defined(DEBUG)
  {
    Label ok;
    // Check that we are always entering from Dart code.
    __ movq(RAX, Immediate(VMTag::kDartCompiledTagId));
    __ cmpq(RAX, Assembler::VMTagAddress());
    __ j(EQUAL, &ok, Assembler::kNearJump);
    __ Stop("Not coming from Dart code.");
    __ Bind(&ok);
  }
#endif

  // Mark that the thread is executing VM code.
  __ movq(Assembler::VMTagAddress(), RBX);

  // Reserve space for arguments and align frame before entering C++ world.
  __ subq(RSP, Immediate(target::NativeArguments::StructSize()));
  if (OS::ActivationFrameAlignment() > 1) {
    __ andq(RSP, Immediate(~(OS::ActivationFrameAlignment() - 1)));
  }

  // Pass target::NativeArguments structure by value and call runtime.
  __ movq(Address(RSP, thread_offset), THR);  // Set thread in NativeArgs.
  // There are no runtime calls to closures, so we do not need to set the tag
  // bits kClosureFunctionBit and kInstanceFunctionBit in argc_tag_.
  __ movq(Address(RSP, argc_tag_offset),
          R10);  // Set argc in target::NativeArguments.
  // Compute argv.
  __ leaq(RAX,
          Address(RBP, R10, TIMES_8,
                  target::frame_layout.param_end_from_fp * target::kWordSize));
  __ movq(Address(RSP, argv_offset),
          RAX);  // Set argv in target::NativeArguments.
  __ addq(RAX,
          Immediate(1 * target::kWordSize));  // Retval is next to 1st argument.
  __ movq(Address(RSP, retval_offset),
          RAX);  // Set retval in target::NativeArguments.
#if defined(_WIN64)
  ASSERT(target::NativeArguments::StructSize() >
         CallingConventions::kRegisterTransferLimit);
  __ movq(CallingConventions::kArg1Reg, RSP);
#endif
  __ CallCFunction(RBX);

  // Mark that the thread is executing Dart code.
  __ movq(Assembler::VMTagAddress(), Immediate(VMTag::kDartCompiledTagId));

  // Reset exit frame information in Isolate structure.
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()),
          Immediate(0));

  // Restore the global object pool after returning from runtime (old space is
  // moving, so the GOP could have been relocated).
  if (FLAG_precompiled_mode && FLAG_use_bare_instructions) {
    __ movq(PP, Address(THR, target::Thread::global_object_pool_offset()));
  }

  __ LeaveStubFrame();

  // The following return can jump to a lazy-deopt stub, which assumes RAX
  // contains a return value and will save it in a GC-visible way.  We therefore
  // have to ensure RAX does not contain any garbage value left from the C
  // function we called (which has return type "void").
  // (See GenerateDeoptimizationSequence::saved_result_slot_from_fp.)
  __ xorq(RAX, RAX);
  __ ret();
}

void StubCodeCompiler::GenerateSharedStub(
    Assembler* assembler,
    bool save_fpu_registers,
    const RuntimeEntry* target,
    intptr_t self_code_stub_offset_from_thread,
    bool allow_return) {
  // We want the saved registers to appear like part of the caller's frame, so
  // we push them before calling EnterStubFrame.
  __ PushRegisters(kDartAvailableCpuRegs,
                   save_fpu_registers ? kAllFpuRegistersList : 0);

  const intptr_t kSavedCpuRegisterSlots =
      Utils::CountOneBitsWord(kDartAvailableCpuRegs);

  const intptr_t kSavedFpuRegisterSlots =
      save_fpu_registers
          ? kNumberOfFpuRegisters * kFpuRegisterSize / target::kWordSize
          : 0;

  const intptr_t kAllSavedRegistersSlots =
      kSavedCpuRegisterSlots + kSavedFpuRegisterSlots;

  // Copy down the return address so the stack layout is correct.
  __ pushq(Address(RSP, kAllSavedRegistersSlots * target::kWordSize));

  __ movq(CODE_REG, Address(THR, self_code_stub_offset_from_thread));

  __ EnterStubFrame();
  __ CallRuntime(*target, /*argument_count=*/0);
  if (!allow_return) {
    __ Breakpoint();
    return;
  }
  __ LeaveStubFrame();

  // Drop "official" return address -- we can just use the one stored above the
  // saved registers.
  __ Drop(1);

  __ PopRegisters(kDartAvailableCpuRegs,
                  save_fpu_registers ? kAllFpuRegistersList : 0);

  __ ret();
}

void StubCodeCompiler::GenerateEnterSafepointStub(Assembler* assembler) {
  RegisterSet all_registers;
  all_registers.AddAllGeneralRegisters();
  __ PushRegisters(all_registers.cpu_registers(),
                   all_registers.fpu_registers());

  __ EnterFrame(0);
  __ ReserveAlignedFrameSpace(0);
  __ movq(RAX, Address(THR, kEnterSafepointRuntimeEntry.OffsetFromThread()));
  __ CallCFunction(RAX);
  __ LeaveFrame();

  __ PopRegisters(all_registers.cpu_registers(), all_registers.fpu_registers());
  __ ret();
}

void StubCodeCompiler::GenerateExitSafepointStub(Assembler* assembler) {
  RegisterSet all_registers;
  all_registers.AddAllGeneralRegisters();
  __ PushRegisters(all_registers.cpu_registers(),
                   all_registers.fpu_registers());

  __ EnterFrame(0);
  __ ReserveAlignedFrameSpace(0);

  // Set the execution state to VM while waiting for the safepoint to end.
  // This isn't strictly necessary but enables tests to check that we're not
  // in native code anymore. See tests/ffi/function_gc_test.dart for example.
  __ movq(Address(THR, target::Thread::execution_state_offset()),
          Immediate(target::Thread::vm_execution_state()));

  __ movq(RAX, Address(THR, kExitSafepointRuntimeEntry.OffsetFromThread()));
  __ CallCFunction(RAX);
  __ LeaveFrame();

  __ PopRegisters(all_registers.cpu_registers(), all_registers.fpu_registers());
  __ ret();
}

void StubCodeCompiler::GenerateVerifyCallbackStub(Assembler* assembler) {
  // SP points to return address, which needs to be the second argument to
  // VerifyCallbackIsolate.
  __ movq(CallingConventions::kArg2Reg, Address(SPREG, 0));

  __ EnterFrame(0);
  __ ReserveAlignedFrameSpace(0);
  __ movq(RAX,
          Address(THR, kVerifyCallbackIsolateRuntimeEntry.OffsetFromThread()));
  __ CallCFunction(RAX);
  __ LeaveFrame();
  __ ret();
}

// Calls native code within a safepoint.
//
// On entry:
//   Stack: arguments set up and aligned for native call, excl. shadow space
//   RBX = target address to call
//
// On exit:
//   Stack pointer lowered by shadow space
//   RBX, R12 clobbered
void StubCodeCompiler::GenerateCallNativeThroughSafepointStub(
    Assembler* assembler) {
  __ TransitionGeneratedToNative(RBX, FPREG);

  __ popq(R12);
  __ CallCFunction(RBX);

  __ TransitionNativeToGenerated();

  // Faster than jmp because it doesn't confuse the branch predictor.
  __ pushq(R12);
  __ ret();
}

// RBX: The extracted method.
// RDX: The type_arguments_field_offset (or 0)
void StubCodeCompiler::GenerateBuildMethodExtractorStub(
    Assembler* assembler,
    const Object& closure_allocation_stub,
    const Object& context_allocation_stub) {
  const intptr_t kReceiverOffsetInWords =
      target::frame_layout.param_end_from_fp + 1;

  __ EnterStubFrame();

  // Push type_arguments vector (or null)
  Label no_type_args;
  __ movq(RCX, Address(THR, target::Thread::object_null_offset()));
  __ cmpq(RDX, Immediate(0));
  __ j(EQUAL, &no_type_args, Assembler::kNearJump);
  __ movq(RAX, Address(RBP, target::kWordSize * kReceiverOffsetInWords));
  __ movq(RCX, Address(RAX, RDX, TIMES_1, 0));
  __ Bind(&no_type_args);
  __ pushq(RCX);

  // Push extracted method.
  __ pushq(RBX);

  // Allocate context.
  {
    Label done, slow_path;
    __ TryAllocateArray(kContextCid, target::Context::InstanceSize(1),
                        &slow_path, Assembler::kFarJump,
                        RAX,  // instance
                        RSI,  // end address
                        RDI);
    __ movq(RSI, Address(THR, target::Thread::object_null_offset()));
    __ movq(FieldAddress(RAX, target::Context::parent_offset()), RSI);
    __ movq(FieldAddress(RAX, target::Context::num_variables_offset()),
            Immediate(1));
    __ jmp(&done);

    __ Bind(&slow_path);

    __ LoadImmediate(/*num_vars=*/R10, Immediate(1));
    __ LoadObject(CODE_REG, context_allocation_stub);
    __ call(FieldAddress(CODE_REG, target::Code::entry_point_offset()));

    __ Bind(&done);
  }

  // Store receiver in context
  __ movq(RSI, Address(RBP, target::kWordSize * kReceiverOffsetInWords));
  __ StoreIntoObject(
      RAX, FieldAddress(RAX, target::Context::variable_offset(0)), RSI);

  // Push context.
  __ pushq(RAX);

  // Allocate closure.
  __ LoadObject(CODE_REG, closure_allocation_stub);
  __ call(FieldAddress(
      CODE_REG, target::Code::entry_point_offset(CodeEntryKind::kUnchecked)));

  // Populate closure object.
  __ popq(RCX);  // Pop context.
  __ StoreIntoObject(RAX, FieldAddress(RAX, target::Closure::context_offset()),
                     RCX);
  __ popq(RCX);  // Pop extracted method.
  __ StoreIntoObjectNoBarrier(
      RAX, FieldAddress(RAX, target::Closure::function_offset()), RCX);
  __ popq(RCX);  // Pop type argument vector.
  __ StoreIntoObjectNoBarrier(
      RAX,
      FieldAddress(RAX, target::Closure::instantiator_type_arguments_offset()),
      RCX);
  __ LoadObject(RCX, EmptyTypeArguments());
  __ StoreIntoObjectNoBarrier(
      RAX, FieldAddress(RAX, target::Closure::delayed_type_arguments_offset()),
      RCX);

  __ LeaveStubFrame();
  __ Ret();
}

void StubCodeCompiler::GenerateNullErrorSharedWithoutFPURegsStub(
    Assembler* assembler) {
  GenerateSharedStub(
      assembler, /*save_fpu_registers=*/false, &kNullErrorRuntimeEntry,
      target::Thread::null_error_shared_without_fpu_regs_stub_offset(),
      /*allow_return=*/false);
}

void StubCodeCompiler::GenerateNullErrorSharedWithFPURegsStub(
    Assembler* assembler) {
  GenerateSharedStub(
      assembler, /*save_fpu_registers=*/true, &kNullErrorRuntimeEntry,
      target::Thread::null_error_shared_with_fpu_regs_stub_offset(),
      /*allow_return=*/false);
}

void StubCodeCompiler::GenerateStackOverflowSharedWithoutFPURegsStub(
    Assembler* assembler) {
  GenerateSharedStub(
      assembler, /*save_fpu_registers=*/false, &kStackOverflowRuntimeEntry,
      target::Thread::stack_overflow_shared_without_fpu_regs_stub_offset(),
      /*allow_return=*/true);
}

void StubCodeCompiler::GenerateStackOverflowSharedWithFPURegsStub(
    Assembler* assembler) {
  GenerateSharedStub(
      assembler, /*save_fpu_registers=*/true, &kStackOverflowRuntimeEntry,
      target::Thread::stack_overflow_shared_with_fpu_regs_stub_offset(),
      /*allow_return=*/true);
}

// Input parameters:
//   RSP : points to return address.
//   RDI : stop message (const char*).
// Must preserve all registers.
void StubCodeCompiler::GeneratePrintStopMessageStub(Assembler* assembler) {
  __ EnterCallRuntimeFrame(0);
// Call the runtime leaf function. RDI already contains the parameter.
#if defined(_WIN64)
  __ movq(CallingConventions::kArg1Reg, RDI);
#endif
  __ CallRuntime(kPrintStopMessageRuntimeEntry, 1);
  __ LeaveCallRuntimeFrame();
  __ ret();
}

// Input parameters:
//   RSP : points to return address.
//   RSP + 8 : address of return value.
//   RAX : address of first argument in argument array.
//   RBX : address of the native function to call.
//   R10 : argc_tag including number of arguments and function kind.
static void GenerateCallNativeWithWrapperStub(Assembler* assembler,
                                              Address wrapper_address) {
  const intptr_t native_args_struct_offset = 0;
  const intptr_t thread_offset =
      target::NativeArguments::thread_offset() + native_args_struct_offset;
  const intptr_t argc_tag_offset =
      target::NativeArguments::argc_tag_offset() + native_args_struct_offset;
  const intptr_t argv_offset =
      target::NativeArguments::argv_offset() + native_args_struct_offset;
  const intptr_t retval_offset =
      target::NativeArguments::retval_offset() + native_args_struct_offset;

  __ EnterStubFrame();

  // Save exit frame information to enable stack walking as we are about
  // to transition to native code.
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()), RBP);

#if defined(DEBUG)
  {
    Label ok;
    // Check that we are always entering from Dart code.
    __ movq(R8, Immediate(VMTag::kDartCompiledTagId));
    __ cmpq(R8, Assembler::VMTagAddress());
    __ j(EQUAL, &ok, Assembler::kNearJump);
    __ Stop("Not coming from Dart code.");
    __ Bind(&ok);
  }
#endif

  // Mark that the thread is executing native code.
  __ movq(Assembler::VMTagAddress(), RBX);

  // Reserve space for the native arguments structure passed on the stack (the
  // outgoing pointer parameter to the native arguments structure is passed in
  // RDI) and align frame before entering the C++ world.
  __ subq(RSP, Immediate(target::NativeArguments::StructSize()));
  if (OS::ActivationFrameAlignment() > 1) {
    __ andq(RSP, Immediate(~(OS::ActivationFrameAlignment() - 1)));
  }

  // Pass target::NativeArguments structure by value and call native function.
  __ movq(Address(RSP, thread_offset), THR);  // Set thread in NativeArgs.
  __ movq(Address(RSP, argc_tag_offset),
          R10);  // Set argc in target::NativeArguments.
  __ movq(Address(RSP, argv_offset),
          RAX);  // Set argv in target::NativeArguments.
  __ leaq(RAX,
          Address(RBP, 2 * target::kWordSize));  // Compute return value addr.
  __ movq(Address(RSP, retval_offset),
          RAX);  // Set retval in target::NativeArguments.

  // Pass the pointer to the target::NativeArguments.
  __ movq(CallingConventions::kArg1Reg, RSP);
  // Pass pointer to function entrypoint.
  __ movq(CallingConventions::kArg2Reg, RBX);

  __ movq(RAX, wrapper_address);
  __ CallCFunction(RAX);

  // Mark that the thread is executing Dart code.
  __ movq(Assembler::VMTagAddress(), Immediate(VMTag::kDartCompiledTagId));

  // Reset exit frame information in Isolate structure.
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()),
          Immediate(0));

  // Restore the global object pool after returning from runtime (old space is
  // moving, so the GOP could have been relocated).
  if (FLAG_precompiled_mode && FLAG_use_bare_instructions) {
    __ movq(PP, Address(THR, target::Thread::global_object_pool_offset()));
  }

  __ LeaveStubFrame();
  __ ret();
}

void StubCodeCompiler::GenerateCallNoScopeNativeStub(Assembler* assembler) {
  GenerateCallNativeWithWrapperStub(
      assembler,
      Address(THR,
              target::Thread::no_scope_native_wrapper_entry_point_offset()));
}

void StubCodeCompiler::GenerateCallAutoScopeNativeStub(Assembler* assembler) {
  GenerateCallNativeWithWrapperStub(
      assembler,
      Address(THR,
              target::Thread::auto_scope_native_wrapper_entry_point_offset()));
}

// Input parameters:
//   RSP : points to return address.
//   RSP + 8 : address of return value.
//   RAX : address of first argument in argument array.
//   RBX : address of the native function to call.
//   R10 : argc_tag including number of arguments and function kind.
void StubCodeCompiler::GenerateCallBootstrapNativeStub(Assembler* assembler) {
  const intptr_t native_args_struct_offset = 0;
  const intptr_t thread_offset =
      target::NativeArguments::thread_offset() + native_args_struct_offset;
  const intptr_t argc_tag_offset =
      target::NativeArguments::argc_tag_offset() + native_args_struct_offset;
  const intptr_t argv_offset =
      target::NativeArguments::argv_offset() + native_args_struct_offset;
  const intptr_t retval_offset =
      target::NativeArguments::retval_offset() + native_args_struct_offset;

  __ EnterStubFrame();

  // Save exit frame information to enable stack walking as we are about
  // to transition to native code.
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()), RBP);

#if defined(DEBUG)
  {
    Label ok;
    // Check that we are always entering from Dart code.
    __ movq(R8, Immediate(VMTag::kDartCompiledTagId));
    __ cmpq(R8, Assembler::VMTagAddress());
    __ j(EQUAL, &ok, Assembler::kNearJump);
    __ Stop("Not coming from Dart code.");
    __ Bind(&ok);
  }
#endif

  // Mark that the thread is executing native code.
  __ movq(Assembler::VMTagAddress(), RBX);

  // Reserve space for the native arguments structure passed on the stack (the
  // outgoing pointer parameter to the native arguments structure is passed in
  // RDI) and align frame before entering the C++ world.
  __ subq(RSP, Immediate(target::NativeArguments::StructSize()));
  if (OS::ActivationFrameAlignment() > 1) {
    __ andq(RSP, Immediate(~(OS::ActivationFrameAlignment() - 1)));
  }

  // Pass target::NativeArguments structure by value and call native function.
  __ movq(Address(RSP, thread_offset), THR);  // Set thread in NativeArgs.
  __ movq(Address(RSP, argc_tag_offset),
          R10);  // Set argc in target::NativeArguments.
  __ movq(Address(RSP, argv_offset),
          RAX);  // Set argv in target::NativeArguments.
  __ leaq(RAX,
          Address(RBP, 2 * target::kWordSize));  // Compute return value addr.
  __ movq(Address(RSP, retval_offset),
          RAX);  // Set retval in target::NativeArguments.

  // Pass the pointer to the target::NativeArguments.
  __ movq(CallingConventions::kArg1Reg, RSP);
  __ CallCFunction(RBX);

  // Mark that the thread is executing Dart code.
  __ movq(Assembler::VMTagAddress(), Immediate(VMTag::kDartCompiledTagId));

  // Reset exit frame information in Isolate structure.
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()),
          Immediate(0));

  // Restore the global object pool after returning from runtime (old space is
  // moving, so the GOP could have been relocated).
  if (FLAG_precompiled_mode && FLAG_use_bare_instructions) {
    __ movq(PP, Address(THR, target::Thread::global_object_pool_offset()));
  }

  __ LeaveStubFrame();
  __ ret();
}

// Input parameters:
//   R10: arguments descriptor array.
void StubCodeCompiler::GenerateCallStaticFunctionStub(Assembler* assembler) {
  __ EnterStubFrame();
  __ pushq(R10);  // Preserve arguments descriptor array.
  // Setup space on stack for return value.
  __ pushq(Immediate(0));
  __ CallRuntime(kPatchStaticCallRuntimeEntry, 0);
  __ popq(CODE_REG);  // Get Code object result.
  __ popq(R10);       // Restore arguments descriptor array.
  // Remove the stub frame as we are about to jump to the dart function.
  __ LeaveStubFrame();

  __ movq(RBX, FieldAddress(CODE_REG, target::Code::entry_point_offset()));
  __ jmp(RBX);
}

// Called from a static call only when an invalid code has been entered
// (invalid because its function was optimized or deoptimized).
// R10: arguments descriptor array.
void StubCodeCompiler::GenerateFixCallersTargetStub(Assembler* assembler) {
  Label monomorphic;
  __ BranchOnMonomorphicCheckedEntryJIT(&monomorphic);

  // This was a static call.
  // Load code pointer to this stub from the thread:
  // The one that is passed in, is not correct - it points to the code object
  // that needs to be replaced.
  __ movq(CODE_REG,
          Address(THR, target::Thread::fix_callers_target_code_offset()));
  __ EnterStubFrame();
  __ pushq(R10);  // Preserve arguments descriptor array.
  // Setup space on stack for return value.
  __ pushq(Immediate(0));
  __ CallRuntime(kFixCallersTargetRuntimeEntry, 0);
  __ popq(CODE_REG);  // Get Code object.
  __ popq(R10);       // Restore arguments descriptor array.
  __ movq(RAX, FieldAddress(CODE_REG, target::Code::entry_point_offset()));
  __ LeaveStubFrame();
  __ jmp(RAX);
  __ int3();

  __ Bind(&monomorphic);
  // This was a switchable call.
  // Load code pointer to this stub from the thread:
  // The one that is passed in, is not correct - it points to the code object
  // that needs to be replaced.
  __ movq(CODE_REG,
          Address(THR, target::Thread::fix_callers_target_code_offset()));
  __ EnterStubFrame();
  __ pushq(RBX);           // Preserve cache (guarded CID as Smi).
  __ pushq(RDX);           // Preserve receiver.
  __ pushq(Immediate(0));  // Result slot.
  __ CallRuntime(kFixCallersTargetMonomorphicRuntimeEntry, 0);
  __ popq(CODE_REG);  // Get Code object.
  __ popq(RDX);       // Restore receiver.
  __ popq(RBX);       // Restore cache (guarded CID as Smi).
  __ movq(RAX, FieldAddress(CODE_REG, target::Code::entry_point_offset(
                                          CodeEntryKind::kMonomorphic)));
  __ LeaveStubFrame();
  __ jmp(RAX);
  __ int3();
}

// Called from object allocate instruction when the allocation stub has been
// disabled.
void StubCodeCompiler::GenerateFixAllocationStubTargetStub(
    Assembler* assembler) {
  // Load code pointer to this stub from the thread:
  // The one that is passed in, is not correct - it points to the code object
  // that needs to be replaced.
  __ movq(CODE_REG,
          Address(THR, target::Thread::fix_allocation_stub_code_offset()));
  __ EnterStubFrame();
  // Setup space on stack for return value.
  __ pushq(Immediate(0));
  __ CallRuntime(kFixAllocationStubTargetRuntimeEntry, 0);
  __ popq(CODE_REG);  // Get Code object.
  __ movq(RAX, FieldAddress(CODE_REG, target::Code::entry_point_offset()));
  __ LeaveStubFrame();
  __ jmp(RAX);
  __ int3();
}

// Input parameters:
//   R10: smi-tagged argument count, may be zero.
//   RBP[target::frame_layout.param_end_from_fp + 1]: last argument.
static void PushArrayOfArguments(Assembler* assembler) {
  __ LoadObject(R12, NullObject());
  // Allocate array to store arguments of caller.
  __ movq(RBX, R12);  // Null element type for raw Array.
  __ Call(StubCodeAllocateArray());
  __ SmiUntag(R10);
  // RAX: newly allocated array.
  // R10: length of the array (was preserved by the stub).
  __ pushq(RAX);  // Array is in RAX and on top of stack.
  __ leaq(R12,
          Address(RBP, R10, TIMES_8,
                  target::frame_layout.param_end_from_fp * target::kWordSize));
  __ leaq(RBX, FieldAddress(RAX, target::Array::data_offset()));
  // R12: address of first argument on stack.
  // RBX: address of first argument in array.
  Label loop, loop_condition;
#if defined(DEBUG)
  static const bool kJumpLength = Assembler::kFarJump;
#else
  static const bool kJumpLength = Assembler::kNearJump;
#endif  // DEBUG
  __ jmp(&loop_condition, kJumpLength);
  __ Bind(&loop);
  __ movq(RDI, Address(R12, 0));
  // Generational barrier is needed, array is not necessarily in new space.
  __ StoreIntoObject(RAX, Address(RBX, 0), RDI);
  __ addq(RBX, Immediate(target::kWordSize));
  __ subq(R12, Immediate(target::kWordSize));
  __ Bind(&loop_condition);
  __ decq(R10);
  __ j(POSITIVE, &loop, Assembler::kNearJump);
}

// Used by eager and lazy deoptimization. Preserve result in RAX if necessary.
// This stub translates optimized frame into unoptimized frame. The optimized
// frame can contain values in registers and on stack, the unoptimized
// frame contains all values on stack.
// Deoptimization occurs in following steps:
// - Push all registers that can contain values.
// - Call C routine to copy the stack and saved registers into temporary buffer.
// - Adjust caller's frame to correct unoptimized frame size.
// - Fill the unoptimized frame.
// - Materialize objects that require allocation (e.g. Double instances).
// GC can occur only after frame is fully rewritten.
// Stack after EnterDartFrame(0, PP, kNoRegister) below:
//   +------------------+
//   | Saved PP         | <- PP
//   +------------------+
//   | PC marker        | <- TOS
//   +------------------+
//   | Saved FP         | <- FP of stub
//   +------------------+
//   | return-address   |  (deoptimization point)
//   +------------------+
//   | Saved CODE_REG   |
//   +------------------+
//   | ...              | <- SP of optimized frame
//
// Parts of the code cannot GC, part of the code can GC.
static void GenerateDeoptimizationSequence(Assembler* assembler,
                                           DeoptStubKind kind) {
  // DeoptimizeCopyFrame expects a Dart frame, i.e. EnterDartFrame(0), but there
  // is no need to set the correct PC marker or load PP, since they get patched.
  __ EnterStubFrame();

  // The code in this frame may not cause GC. kDeoptimizeCopyFrameRuntimeEntry
  // and kDeoptimizeFillFrameRuntimeEntry are leaf runtime calls.
  const intptr_t saved_result_slot_from_fp =
      target::frame_layout.first_local_from_fp + 1 -
      (kNumberOfCpuRegisters - RAX);
  const intptr_t saved_exception_slot_from_fp =
      target::frame_layout.first_local_from_fp + 1 -
      (kNumberOfCpuRegisters - RAX);
  const intptr_t saved_stacktrace_slot_from_fp =
      target::frame_layout.first_local_from_fp + 1 -
      (kNumberOfCpuRegisters - RDX);
  // Result in RAX is preserved as part of pushing all registers below.

  // Push registers in their enumeration order: lowest register number at
  // lowest address.
  for (intptr_t i = kNumberOfCpuRegisters - 1; i >= 0; i--) {
    if (i == CODE_REG) {
      // Save the original value of CODE_REG pushed before invoking this stub
      // instead of the value used to call this stub.
      __ pushq(Address(RBP, 2 * target::kWordSize));
    } else {
      __ pushq(static_cast<Register>(i));
    }
  }
  __ subq(RSP, Immediate(kNumberOfXmmRegisters * kFpuRegisterSize));
  intptr_t offset = 0;
  for (intptr_t reg_idx = 0; reg_idx < kNumberOfXmmRegisters; ++reg_idx) {
    XmmRegister xmm_reg = static_cast<XmmRegister>(reg_idx);
    __ movups(Address(RSP, offset), xmm_reg);
    offset += kFpuRegisterSize;
  }

  // Pass address of saved registers block.
  __ movq(CallingConventions::kArg1Reg, RSP);
  bool is_lazy =
      (kind == kLazyDeoptFromReturn) || (kind == kLazyDeoptFromThrow);
  __ movq(CallingConventions::kArg2Reg, Immediate(is_lazy ? 1 : 0));
  __ ReserveAlignedFrameSpace(0);  // Ensure stack is aligned before the call.
  __ CallRuntime(kDeoptimizeCopyFrameRuntimeEntry, 2);
  // Result (RAX) is stack-size (FP - SP) in bytes.

  if (kind == kLazyDeoptFromReturn) {
    // Restore result into RBX temporarily.
    __ movq(RBX, Address(RBP, saved_result_slot_from_fp * target::kWordSize));
  } else if (kind == kLazyDeoptFromThrow) {
    // Restore result into RBX temporarily.
    __ movq(RBX,
            Address(RBP, saved_exception_slot_from_fp * target::kWordSize));
    __ movq(RDX,
            Address(RBP, saved_stacktrace_slot_from_fp * target::kWordSize));
  }

  // There is a Dart Frame on the stack. We must restore PP and leave frame.
  __ RestoreCodePointer();
  __ LeaveStubFrame();

  __ popq(RCX);       // Preserve return address.
  __ movq(RSP, RBP);  // Discard optimized frame.
  __ subq(RSP, RAX);  // Reserve space for deoptimized frame.
  __ pushq(RCX);      // Restore return address.

  // DeoptimizeFillFrame expects a Dart frame, i.e. EnterDartFrame(0), but there
  // is no need to set the correct PC marker or load PP, since they get patched.
  __ EnterStubFrame();

  if (kind == kLazyDeoptFromReturn) {
    __ pushq(RBX);  // Preserve result as first local.
  } else if (kind == kLazyDeoptFromThrow) {
    __ pushq(RBX);  // Preserve exception as first local.
    __ pushq(RDX);  // Preserve stacktrace as second local.
  }
  __ ReserveAlignedFrameSpace(0);
  // Pass last FP as a parameter.
  __ movq(CallingConventions::kArg1Reg, RBP);
  __ CallRuntime(kDeoptimizeFillFrameRuntimeEntry, 1);
  if (kind == kLazyDeoptFromReturn) {
    // Restore result into RBX.
    __ movq(RBX, Address(RBP, target::frame_layout.first_local_from_fp *
                                  target::kWordSize));
  } else if (kind == kLazyDeoptFromThrow) {
    // Restore exception into RBX.
    __ movq(RBX, Address(RBP, target::frame_layout.first_local_from_fp *
                                  target::kWordSize));
    // Restore stacktrace into RDX.
    __ movq(RDX, Address(RBP, (target::frame_layout.first_local_from_fp - 1) *
                                  target::kWordSize));
  }
  // Code above cannot cause GC.
  // There is a Dart Frame on the stack. We must restore PP and leave frame.
  __ RestoreCodePointer();
  __ LeaveStubFrame();

  // Frame is fully rewritten at this point and it is safe to perform a GC.
  // Materialize any objects that were deferred by FillFrame because they
  // require allocation.
  // Enter stub frame with loading PP. The caller's PP is not materialized yet.
  __ EnterStubFrame();
  if (kind == kLazyDeoptFromReturn) {
    __ pushq(RBX);  // Preserve result, it will be GC-d here.
  } else if (kind == kLazyDeoptFromThrow) {
    __ pushq(RBX);  // Preserve exception.
    __ pushq(RDX);  // Preserve stacktrace.
  }
  __ pushq(Immediate(target::ToRawSmi(0)));  // Space for the result.
  __ CallRuntime(kDeoptimizeMaterializeRuntimeEntry, 0);
  // Result tells stub how many bytes to remove from the expression stack
  // of the bottom-most frame. They were used as materialization arguments.
  __ popq(RBX);
  __ SmiUntag(RBX);
  if (kind == kLazyDeoptFromReturn) {
    __ popq(RAX);  // Restore result.
  } else if (kind == kLazyDeoptFromThrow) {
    __ popq(RDX);  // Restore stacktrace.
    __ popq(RAX);  // Restore exception.
  }
  __ LeaveStubFrame();

  __ popq(RCX);       // Pop return address.
  __ addq(RSP, RBX);  // Remove materialization arguments.
  __ pushq(RCX);      // Push return address.
  // The caller is responsible for emitting the return instruction.
}

// RAX: result, must be preserved
void StubCodeCompiler::GenerateDeoptimizeLazyFromReturnStub(
    Assembler* assembler) {
  // Push zap value instead of CODE_REG for lazy deopt.
  __ pushq(Immediate(kZapCodeReg));
  // Return address for "call" to deopt stub.
  __ pushq(Immediate(kZapReturnAddress));
  __ movq(CODE_REG,
          Address(THR, target::Thread::lazy_deopt_from_return_stub_offset()));
  GenerateDeoptimizationSequence(assembler, kLazyDeoptFromReturn);
  __ ret();
}

// RAX: exception, must be preserved
// RDX: stacktrace, must be preserved
void StubCodeCompiler::GenerateDeoptimizeLazyFromThrowStub(
    Assembler* assembler) {
  // Push zap value instead of CODE_REG for lazy deopt.
  __ pushq(Immediate(kZapCodeReg));
  // Return address for "call" to deopt stub.
  __ pushq(Immediate(kZapReturnAddress));
  __ movq(CODE_REG,
          Address(THR, target::Thread::lazy_deopt_from_throw_stub_offset()));
  GenerateDeoptimizationSequence(assembler, kLazyDeoptFromThrow);
  __ ret();
}

void StubCodeCompiler::GenerateDeoptimizeStub(Assembler* assembler) {
  __ popq(TMP);
  __ pushq(CODE_REG);
  __ pushq(TMP);
  __ movq(CODE_REG, Address(THR, target::Thread::deoptimize_stub_offset()));
  GenerateDeoptimizationSequence(assembler, kEagerDeopt);
  __ ret();
}

static void GenerateDispatcherCode(Assembler* assembler,
                                   Label* call_target_function) {
  __ Comment("NoSuchMethodDispatch");
  // When lazily generated invocation dispatchers are disabled, the
  // miss-handler may return null.
  __ CompareObject(RAX, NullObject());
  __ j(NOT_EQUAL, call_target_function);
  __ EnterStubFrame();
  // Load the receiver.
  __ movq(RDI, FieldAddress(R10, target::ArgumentsDescriptor::count_offset()));
  __ movq(RAX,
          Address(RBP, RDI, TIMES_HALF_WORD_SIZE,
                  target::frame_layout.param_end_from_fp * target::kWordSize));
  __ pushq(Immediate(0));  // Setup space on stack for result.
  __ pushq(RAX);           // Receiver.
  __ pushq(RBX);           // ICData/MegamorphicCache.
  __ pushq(R10);           // Arguments descriptor array.

  // Adjust arguments count.
  __ cmpq(
      FieldAddress(R10, target::ArgumentsDescriptor::type_args_len_offset()),
      Immediate(0));
  __ movq(R10, RDI);
  Label args_count_ok;
  __ j(EQUAL, &args_count_ok, Assembler::kNearJump);
  __ addq(R10, Immediate(target::ToRawSmi(1)));  // Include the type arguments.
  __ Bind(&args_count_ok);

  // R10: Smi-tagged arguments array length.
  PushArrayOfArguments(assembler);
  const intptr_t kNumArgs = 4;
  __ CallRuntime(kNoSuchMethodFromCallStubRuntimeEntry, kNumArgs);
  __ Drop(4);
  __ popq(RAX);  // Return value.
  __ LeaveStubFrame();
  __ ret();
}

void StubCodeCompiler::GenerateMegamorphicMissStub(Assembler* assembler) {
  __ EnterStubFrame();
  // Load the receiver into RAX.  The argument count in the arguments
  // descriptor in R10 is a smi.
  __ movq(RAX, FieldAddress(R10, target::ArgumentsDescriptor::count_offset()));
  // Three words (saved pp, saved fp, stub's pc marker)
  // in the stack above the return address.
  __ movq(RAX,
          Address(RSP, RAX, TIMES_4,
                  target::frame_layout.saved_below_pc() * target::kWordSize));
  // Preserve IC data and arguments descriptor.
  __ pushq(RBX);
  __ pushq(R10);

  // Space for the result of the runtime call.
  __ pushq(Immediate(0));
  __ pushq(RDX);  // Receiver.
  __ pushq(RBX);  // IC data.
  __ pushq(R10);  // Arguments descriptor.
  __ CallRuntime(kMegamorphicCacheMissHandlerRuntimeEntry, 3);
  // Discard arguments.
  __ popq(RAX);
  __ popq(RAX);
  __ popq(RAX);
  __ popq(RAX);  // Return value from the runtime call (function).
  __ popq(R10);  // Restore arguments descriptor.
  __ popq(RBX);  // Restore IC data.
  __ RestoreCodePointer();
  __ LeaveStubFrame();
  if (!FLAG_lazy_dispatchers) {
    Label call_target_function;
    GenerateDispatcherCode(assembler, &call_target_function);
    __ Bind(&call_target_function);
  }
  __ movq(CODE_REG, FieldAddress(RAX, target::Function::code_offset()));
  __ movq(RCX, FieldAddress(RAX, target::Function::entry_point_offset()));
  __ jmp(RCX);
}

// Called for inline allocation of arrays.
// Input parameters:
//   R10 : Array length as Smi.
//   RBX : array element type (either NULL or an instantiated type).
// NOTE: R10 cannot be clobbered here as the caller relies on it being saved.
// The newly allocated object is returned in RAX.
void StubCodeCompiler::GenerateAllocateArrayStub(Assembler* assembler) {
  Label slow_case;
  // Compute the size to be allocated, it is based on the array length
  // and is computed as:
  // RoundedAllocationSize(
  //     (array_length * target::kwordSize) + target::Array::header_size()).
  __ movq(RDI, R10);  // Array Length.
  // Check that length is a positive Smi.
  __ testq(RDI, Immediate(kSmiTagMask));
  if (FLAG_use_slow_path) {
    __ jmp(&slow_case);
  } else {
    __ j(NOT_ZERO, &slow_case);
  }
  __ cmpq(RDI, Immediate(0));
  __ j(LESS, &slow_case);
  // Check for maximum allowed length.
  const Immediate& max_len =
      Immediate(target::ToRawSmi(target::Array::kMaxNewSpaceElements));
  __ cmpq(RDI, max_len);
  __ j(GREATER, &slow_case);

  // Check for allocation tracing.
  NOT_IN_PRODUCT(
      __ MaybeTraceAllocation(kArrayCid, &slow_case, Assembler::kFarJump));

  const intptr_t fixed_size_plus_alignment_padding =
      target::Array::header_size() + target::ObjectAlignment::kObjectAlignment -
      1;
  // RDI is a Smi.
  __ leaq(RDI, Address(RDI, TIMES_4, fixed_size_plus_alignment_padding));
  ASSERT(kSmiTagShift == 1);
  __ andq(RDI, Immediate(-target::ObjectAlignment::kObjectAlignment));

  const intptr_t cid = kArrayCid;
  __ movq(RAX, Address(THR, target::Thread::top_offset()));

  // RDI: allocation size.
  __ movq(RCX, RAX);
  __ addq(RCX, RDI);
  __ j(CARRY, &slow_case);

  // Check if the allocation fits into the remaining space.
  // RAX: potential new object start.
  // RCX: potential next object start.
  // RDI: allocation size.
  __ cmpq(RCX, Address(THR, target::Thread::end_offset()));
  __ j(ABOVE_EQUAL, &slow_case);

  // Successfully allocated the object(s), now update top to point to
  // next object start and initialize the object.
  __ movq(Address(THR, target::Thread::top_offset()), RCX);
  __ addq(RAX, Immediate(kHeapObjectTag));
  NOT_IN_PRODUCT(__ UpdateAllocationStatsWithSize(cid, RDI));
  // Initialize the tags.
  // RAX: new object start as a tagged pointer.
  // RDI: allocation size.
  {
    Label size_tag_overflow, done;
    __ cmpq(RDI, Immediate(target::RawObject::kSizeTagMaxSizeTag));
    __ j(ABOVE, &size_tag_overflow, Assembler::kNearJump);
    __ shlq(RDI, Immediate(target::RawObject::kTagBitsSizeTagPos -
                           target::ObjectAlignment::kObjectAlignmentLog2));
    __ jmp(&done, Assembler::kNearJump);

    __ Bind(&size_tag_overflow);
    __ LoadImmediate(RDI, Immediate(0));
    __ Bind(&done);

    // Get the class index and insert it into the tags.
    uint32_t tags = target::MakeTagWordForNewSpaceObject(cid, 0);
    __ orq(RDI, Immediate(tags));
    __ movq(FieldAddress(RAX, target::Array::tags_offset()), RDI);  // Tags.
  }

  // RAX: new object start as a tagged pointer.
  // Store the type argument field.
  // No generational barrier needed, since we store into a new object.
  __ StoreIntoObjectNoBarrier(
      RAX, FieldAddress(RAX, target::Array::type_arguments_offset()), RBX);

  // Set the length field.
  __ StoreIntoObjectNoBarrier(
      RAX, FieldAddress(RAX, target::Array::length_offset()), R10);

  // Initialize all array elements to raw_null.
  // RAX: new object start as a tagged pointer.
  // RCX: new object end address.
  // RDI: iterator which initially points to the start of the variable
  // data area to be initialized.
  __ LoadObject(R12, NullObject());
  __ leaq(RDI, FieldAddress(RAX, target::Array::header_size()));
  Label done;
  Label init_loop;
  __ Bind(&init_loop);
  __ cmpq(RDI, RCX);
#if defined(DEBUG)
  static const bool kJumpLength = Assembler::kFarJump;
#else
  static const bool kJumpLength = Assembler::kNearJump;
#endif  // DEBUG
  __ j(ABOVE_EQUAL, &done, kJumpLength);
  // No generational barrier needed, since we are storing null.
  __ StoreIntoObjectNoBarrier(RAX, Address(RDI, 0), R12);
  __ addq(RDI, Immediate(target::kWordSize));
  __ jmp(&init_loop, kJumpLength);
  __ Bind(&done);
  __ ret();  // returns the newly allocated object in RAX.

  // Unable to allocate the array using the fast inline code, just call
  // into the runtime.
  __ Bind(&slow_case);
  // Create a stub frame as we are pushing some objects on the stack before
  // calling into the runtime.
  __ EnterStubFrame();
  // Setup space on stack for return value.
  __ pushq(Immediate(0));
  __ pushq(R10);  // Array length as Smi.
  __ pushq(RBX);  // Element type.
  __ CallRuntime(kAllocateArrayRuntimeEntry, 2);
  __ popq(RAX);  // Pop element type argument.
  __ popq(R10);  // Pop array length argument.
  __ popq(RAX);  // Pop return value from return slot.

  // Write-barrier elimination might be enabled for this array (depending on the
  // array length). To be sure we will check if the allocated object is in old
  // space and if so call a leaf runtime to add it to the remembered set.
  EnsureIsNewOrRemembered(assembler);

  __ LeaveStubFrame();
  __ ret();
}

// Called when invoking Dart code from C++ (VM code).
// Input parameters:
//   RSP : points to return address.
//   RDI : target code
//   RSI : arguments descriptor array.
//   RDX : arguments array.
//   RCX : current thread.
void StubCodeCompiler::GenerateInvokeDartCodeStub(Assembler* assembler) {
  __ pushq(Address(RSP, 0));  // Marker for the profiler.
  __ EnterFrame(0);

  const Register kTargetCodeReg = CallingConventions::kArg1Reg;
  const Register kArgDescReg = CallingConventions::kArg2Reg;
  const Register kArgsReg = CallingConventions::kArg3Reg;
  const Register kThreadReg = CallingConventions::kArg4Reg;

  // Push code object to PC marker slot.
  __ pushq(Address(kThreadReg, target::Thread::invoke_dart_code_stub_offset()));

  // At this point, the stack looks like:
  // | stub code object
  // | saved RBP                                      | <-- RBP
  // | saved PC (return to DartEntry::InvokeFunction) |

  const intptr_t kInitialOffset = 2;
  // Save arguments descriptor array, later replaced by Smi argument count.
  const intptr_t kArgumentsDescOffset = -(kInitialOffset)*target::kWordSize;
  __ pushq(kArgDescReg);

  // Save C++ ABI callee-saved registers.
  __ PushRegisters(CallingConventions::kCalleeSaveCpuRegisters,
                   CallingConventions::kCalleeSaveXmmRegisters);

  // If any additional (or fewer) values are pushed, the offsets in
  // target::frame_layout.exit_link_slot_from_entry_fp will need to be changed.

  // Set up THR, which caches the current thread in Dart code.
  if (THR != kThreadReg) {
    __ movq(THR, kThreadReg);
  }

  // Save the current VMTag on the stack.
  __ movq(RAX, Assembler::VMTagAddress());
  __ pushq(RAX);

  // Save top resource and top exit frame info. Use RAX as a temporary register.
  // StackFrameIterator reads the top exit frame info saved in this frame.
  __ movq(RAX, Address(THR, target::Thread::top_resource_offset()));
  __ pushq(RAX);
  __ movq(Address(THR, target::Thread::top_resource_offset()), Immediate(0));
  __ movq(RAX, Address(THR, target::Thread::top_exit_frame_info_offset()));
  __ pushq(RAX);

  // The constant target::frame_layout.exit_link_slot_from_entry_fp must be kept
  // in sync with the code above.
  __ EmitEntryFrameVerification();

  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()),
          Immediate(0));

  // Mark that the thread is executing Dart code. Do this after initializing the
  // exit link for the profiler.
  __ movq(Assembler::VMTagAddress(), Immediate(VMTag::kDartCompiledTagId));

  // Load arguments descriptor array into R10, which is passed to Dart code.
  __ movq(R10, Address(kArgDescReg, VMHandles::kOffsetOfRawPtrInHandle));

  // Push arguments. At this point we only need to preserve kTargetCodeReg.
  ASSERT(kTargetCodeReg != RDX);

  // Load number of arguments into RBX and adjust count for type arguments.
  __ movq(RBX, FieldAddress(R10, target::ArgumentsDescriptor::count_offset()));
  __ cmpq(
      FieldAddress(R10, target::ArgumentsDescriptor::type_args_len_offset()),
      Immediate(0));
  Label args_count_ok;
  __ j(EQUAL, &args_count_ok, Assembler::kNearJump);
  __ addq(RBX, Immediate(target::ToRawSmi(1)));  // Include the type arguments.
  __ Bind(&args_count_ok);
  // Save number of arguments as Smi on stack, replacing saved ArgumentsDesc.
  __ movq(Address(RBP, kArgumentsDescOffset), RBX);
  __ SmiUntag(RBX);

  // Compute address of 'arguments array' data area into RDX.
  __ movq(RDX, Address(kArgsReg, VMHandles::kOffsetOfRawPtrInHandle));
  __ leaq(RDX, FieldAddress(RDX, target::Array::data_offset()));

  // Set up arguments for the Dart call.
  Label push_arguments;
  Label done_push_arguments;
  __ j(ZERO, &done_push_arguments, Assembler::kNearJump);
  __ LoadImmediate(RAX, Immediate(0));
  __ Bind(&push_arguments);
  __ pushq(Address(RDX, RAX, TIMES_8, 0));
  __ incq(RAX);
  __ cmpq(RAX, RBX);
  __ j(LESS, &push_arguments, Assembler::kNearJump);
  __ Bind(&done_push_arguments);

  // Call the Dart code entrypoint.
  if (FLAG_precompiled_mode && FLAG_use_bare_instructions) {
    __ movq(PP, Address(THR, target::Thread::global_object_pool_offset()));
  } else {
    __ xorq(PP, PP);  // GC-safe value into PP.
  }
  __ movq(CODE_REG,
          Address(kTargetCodeReg, VMHandles::kOffsetOfRawPtrInHandle));
  __ movq(kTargetCodeReg,
          FieldAddress(CODE_REG, target::Code::entry_point_offset()));
  __ call(kTargetCodeReg);  // R10 is the arguments descriptor array.

  // Read the saved number of passed arguments as Smi.
  __ movq(RDX, Address(RBP, kArgumentsDescOffset));

  // Get rid of arguments pushed on the stack.
  __ leaq(RSP, Address(RSP, RDX, TIMES_4, 0));  // RDX is a Smi.

  // Restore the saved top exit frame info and top resource back into the
  // Isolate structure.
  __ popq(Address(THR, target::Thread::top_exit_frame_info_offset()));
  __ popq(Address(THR, target::Thread::top_resource_offset()));

  // Restore the current VMTag from the stack.
  __ popq(Assembler::VMTagAddress());

  // Restore C++ ABI callee-saved registers.
  __ PopRegisters(CallingConventions::kCalleeSaveCpuRegisters,
                  CallingConventions::kCalleeSaveXmmRegisters);
  __ set_constant_pool_allowed(false);

  // Restore the frame pointer.
  __ LeaveFrame();
  __ popq(RCX);

  __ ret();
}

// Called when invoking compiled Dart code from interpreted Dart code.
// Input parameters:
//   RSP : points to return address.
//   RDI : target raw code
//   RSI : arguments raw descriptor array.
//   RDX : address of first argument.
//   RCX : current thread.
void StubCodeCompiler::GenerateInvokeDartCodeFromBytecodeStub(
    Assembler* assembler) {
#if defined(DART_PRECOMPILED_RUNTIME)
  __ Stop("Not using interpreter");
#else
  __ pushq(Address(RSP, 0));  // Marker for the profiler.
  __ EnterFrame(0);

  const Register kTargetCodeReg = CallingConventions::kArg1Reg;
  const Register kArgDescReg = CallingConventions::kArg2Reg;
  const Register kArg0Reg = CallingConventions::kArg3Reg;
  const Register kThreadReg = CallingConventions::kArg4Reg;

  // Push code object to PC marker slot.
  __ pushq(
      Address(kThreadReg,
              target::Thread::invoke_dart_code_from_bytecode_stub_offset()));

  // At this point, the stack looks like:
  // | stub code object
  // | saved RBP                                         | <-- RBP
  // | saved PC (return to interpreter's InvokeCompiled) |

  const intptr_t kInitialOffset = 2;
  // Save arguments descriptor array, later replaced by Smi argument count.
  const intptr_t kArgumentsDescOffset = -(kInitialOffset)*target::kWordSize;
  __ pushq(kArgDescReg);

  // Save C++ ABI callee-saved registers.
  __ PushRegisters(CallingConventions::kCalleeSaveCpuRegisters,
                   CallingConventions::kCalleeSaveXmmRegisters);

  // If any additional (or fewer) values are pushed, the offsets in
  // target::frame_layout.exit_link_slot_from_entry_fp will need to be changed.

  // Set up THR, which caches the current thread in Dart code.
  if (THR != kThreadReg) {
    __ movq(THR, kThreadReg);
  }

  // Save the current VMTag on the stack.
  __ movq(RAX, Assembler::VMTagAddress());
  __ pushq(RAX);

  // Save top resource and top exit frame info. Use RAX as a temporary register.
  // StackFrameIterator reads the top exit frame info saved in this frame.
  __ movq(RAX, Address(THR, target::Thread::top_resource_offset()));
  __ pushq(RAX);
  __ movq(Address(THR, target::Thread::top_resource_offset()), Immediate(0));
  __ movq(RAX, Address(THR, target::Thread::top_exit_frame_info_offset()));
  __ pushq(RAX);
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()),
          Immediate(0));

  // The constant target::frame_layout.exit_link_slot_from_entry_fp must be kept
  // in sync with the code below.
#if defined(DEBUG)
  {
    Label ok;
    __ leaq(RAX,
            Address(RBP, target::frame_layout.exit_link_slot_from_entry_fp *
                             target::kWordSize));
    __ cmpq(RAX, RSP);
    __ j(EQUAL, &ok);
    __ Stop("target::frame_layout.exit_link_slot_from_entry_fp mismatch");
    __ Bind(&ok);
  }
#endif

  // Mark that the thread is executing Dart code. Do this after initializing the
  // exit link for the profiler.
  __ movq(Assembler::VMTagAddress(), Immediate(VMTag::kDartCompiledTagId));

  // Load arguments descriptor array into R10, which is passed to Dart code.
  __ movq(R10, kArgDescReg);

  // Push arguments. At this point we only need to preserve kTargetCodeReg.
  ASSERT(kTargetCodeReg != RDX);

  // Load number of arguments into RBX and adjust count for type arguments.
  __ movq(RBX, FieldAddress(R10, target::ArgumentsDescriptor::count_offset()));
  __ cmpq(
      FieldAddress(R10, target::ArgumentsDescriptor::type_args_len_offset()),
      Immediate(0));
  Label args_count_ok;
  __ j(EQUAL, &args_count_ok, Assembler::kNearJump);
  __ addq(RBX, Immediate(target::ToRawSmi(1)));  // Include the type arguments.
  __ Bind(&args_count_ok);
  // Save number of arguments as Smi on stack, replacing saved ArgumentsDesc.
  __ movq(Address(RBP, kArgumentsDescOffset), RBX);
  __ SmiUntag(RBX);

  // Compute address of first argument into RDX.
  if (kArg0Reg != RDX) {  // Different registers on WIN64.
    __ movq(RDX, kArg0Reg);
  }

  // Set up arguments for the Dart call.
  Label push_arguments;
  Label done_push_arguments;
  __ j(ZERO, &done_push_arguments, Assembler::kNearJump);
  __ LoadImmediate(RAX, Immediate(0));
  __ Bind(&push_arguments);
  __ pushq(Address(RDX, RAX, TIMES_8, 0));
  __ incq(RAX);
  __ cmpq(RAX, RBX);
  __ j(LESS, &push_arguments, Assembler::kNearJump);
  __ Bind(&done_push_arguments);

  // Call the Dart code entrypoint.
  __ xorq(PP, PP);  // GC-safe value into PP.
  __ movq(CODE_REG, kTargetCodeReg);
  __ movq(kTargetCodeReg,
          FieldAddress(CODE_REG, target::Code::entry_point_offset()));
  __ call(kTargetCodeReg);  // R10 is the arguments descriptor array.

  // Read the saved number of passed arguments as Smi.
  __ movq(RDX, Address(RBP, kArgumentsDescOffset));

  // Get rid of arguments pushed on the stack.
  __ leaq(RSP, Address(RSP, RDX, TIMES_4, 0));  // RDX is a Smi.

  // Restore the saved top exit frame info and top resource back into the
  // Isolate structure.
  __ popq(Address(THR, target::Thread::top_exit_frame_info_offset()));
  __ popq(Address(THR, target::Thread::top_resource_offset()));

  // Restore the current VMTag from the stack.
  __ popq(Assembler::VMTagAddress());

  // Restore C++ ABI callee-saved registers.
  __ PopRegisters(CallingConventions::kCalleeSaveCpuRegisters,
                  CallingConventions::kCalleeSaveXmmRegisters);
  __ set_constant_pool_allowed(false);

  // Restore the frame pointer.
  __ LeaveFrame();
  __ popq(RCX);

  __ ret();
#endif  // defined(DART_PRECOMPILED_RUNTIME)
}

// Called for inline allocation of contexts.
// Input:
// R10: number of context variables.
// Output:
// RAX: new allocated RawContext object.
void StubCodeCompiler::GenerateAllocateContextStub(Assembler* assembler) {
  __ LoadObject(R9, NullObject());
  if (FLAG_inline_alloc) {
    Label slow_case;
    // First compute the rounded instance size.
    // R10: number of context variables.
    intptr_t fixed_size_plus_alignment_padding =
        (target::Context::header_size() +
         target::ObjectAlignment::kObjectAlignment - 1);
    __ leaq(R13, Address(R10, TIMES_8, fixed_size_plus_alignment_padding));
    __ andq(R13, Immediate(-target::ObjectAlignment::kObjectAlignment));

    // Check for allocation tracing.
    NOT_IN_PRODUCT(
        __ MaybeTraceAllocation(kContextCid, &slow_case, Assembler::kFarJump));

    // Now allocate the object.
    // R10: number of context variables.
    const intptr_t cid = kContextCid;
    __ movq(RAX, Address(THR, target::Thread::top_offset()));
    __ addq(R13, RAX);
    // Check if the allocation fits into the remaining space.
    // RAX: potential new object.
    // R13: potential next object start.
    // R10: number of context variables.
    __ cmpq(R13, Address(THR, target::Thread::end_offset()));
    if (FLAG_use_slow_path) {
      __ jmp(&slow_case);
    } else {
      __ j(ABOVE_EQUAL, &slow_case);
    }

    // Successfully allocated the object, now update top to point to
    // next object start and initialize the object.
    // RAX: new object.
    // R13: next object start.
    // R10: number of context variables.
    __ movq(Address(THR, target::Thread::top_offset()), R13);
    // R13: Size of allocation in bytes.
    __ subq(R13, RAX);
    __ addq(RAX, Immediate(kHeapObjectTag));
    // Generate isolate-independent code to allow sharing between isolates.
    NOT_IN_PRODUCT(__ UpdateAllocationStatsWithSize(cid, R13));

    // Calculate the size tag.
    // RAX: new object.
    // R10: number of context variables.
    {
      Label size_tag_overflow, done;
      __ leaq(R13, Address(R10, TIMES_8, fixed_size_plus_alignment_padding));
      __ andq(R13, Immediate(-target::ObjectAlignment::kObjectAlignment));
      __ cmpq(R13, Immediate(target::RawObject::kSizeTagMaxSizeTag));
      __ j(ABOVE, &size_tag_overflow, Assembler::kNearJump);
      __ shlq(R13, Immediate(target::RawObject::kTagBitsSizeTagPos -
                             target::ObjectAlignment::kObjectAlignmentLog2));
      __ jmp(&done);

      __ Bind(&size_tag_overflow);
      // Set overflow size tag value.
      __ LoadImmediate(R13, Immediate(0));

      __ Bind(&done);
      // RAX: new object.
      // R10: number of context variables.
      // R13: size and bit tags.
      uint32_t tags = target::MakeTagWordForNewSpaceObject(cid, 0);
      __ orq(R13, Immediate(tags));
      __ movq(FieldAddress(RAX, target::Object::tags_offset()), R13);  // Tags.
    }

    // Setup up number of context variables field.
    // RAX: new object.
    // R10: number of context variables as integer value (not object).
    __ movq(FieldAddress(RAX, target::Context::num_variables_offset()), R10);

    // Setup the parent field.
    // RAX: new object.
    // R10: number of context variables.
    // No generational barrier needed, since we are storing null.
    __ StoreIntoObjectNoBarrier(
        RAX, FieldAddress(RAX, target::Context::parent_offset()), R9);

    // Initialize the context variables.
    // RAX: new object.
    // R10: number of context variables.
    {
      Label loop, entry;
      __ leaq(R13, FieldAddress(RAX, target::Context::variable_offset(0)));
#if defined(DEBUG)
      static const bool kJumpLength = Assembler::kFarJump;
#else
      static const bool kJumpLength = Assembler::kNearJump;
#endif  // DEBUG
      __ jmp(&entry, kJumpLength);
      __ Bind(&loop);
      __ decq(R10);
      // No generational barrier needed, since we are storing null.
      __ StoreIntoObjectNoBarrier(RAX, Address(R13, R10, TIMES_8, 0), R9);
      __ Bind(&entry);
      __ cmpq(R10, Immediate(0));
      __ j(NOT_EQUAL, &loop, Assembler::kNearJump);
    }

    // Done allocating and initializing the context.
    // RAX: new object.
    __ ret();

    __ Bind(&slow_case);
  }
  // Create a stub frame.
  __ EnterStubFrame();
  __ pushq(R9);  // Setup space on stack for the return value.
  __ SmiTag(R10);
  __ pushq(R10);  // Push number of context variables.
  __ CallRuntime(kAllocateContextRuntimeEntry, 1);  // Allocate context.
  __ popq(RAX);  // Pop number of context variables argument.
  __ popq(RAX);  // Pop the new context object.

  // Write-barrier elimination might be enabled for this context (depending on
  // the size). To be sure we will check if the allocated object is in old
  // space and if so call a leaf runtime to add it to the remembered set.
  EnsureIsNewOrRemembered(assembler, /*preserve_registers=*/false);

  // RAX: new object
  // Restore the frame pointer.
  __ LeaveStubFrame();
  __ ret();
}

void StubCodeCompiler::GenerateWriteBarrierWrappersStub(Assembler* assembler) {
  for (intptr_t i = 0; i < kNumberOfCpuRegisters; ++i) {
    if ((kDartAvailableCpuRegs & (1 << i)) == 0) continue;

    Register reg = static_cast<Register>(i);
    intptr_t start = __ CodeSize();
    __ pushq(kWriteBarrierObjectReg);
    __ movq(kWriteBarrierObjectReg, reg);
    __ call(Address(THR, target::Thread::write_barrier_entry_point_offset()));
    __ popq(kWriteBarrierObjectReg);
    __ ret();
    intptr_t end = __ CodeSize();

    RELEASE_ASSERT(end - start == kStoreBufferWrapperSize);
  }
}

// Helper stub to implement Assembler::StoreIntoObject/Array.
// Input parameters:
//   RDX: Object (old)
//   RAX: Value (old or new)
//   R13: Slot
// If RAX is new, add RDX to the store buffer. Otherwise RAX is old, mark RAX
// and add it to the mark list.
COMPILE_ASSERT(kWriteBarrierObjectReg == RDX);
COMPILE_ASSERT(kWriteBarrierValueReg == RAX);
COMPILE_ASSERT(kWriteBarrierSlotReg == R13);
static void GenerateWriteBarrierStubHelper(Assembler* assembler,
                                           Address stub_code,
                                           bool cards) {
  Label add_to_mark_stack, remember_card;
  __ testq(RAX, Immediate(1 << target::ObjectAlignment::kNewObjectBitPosition));
  __ j(ZERO, &add_to_mark_stack);

  if (cards) {
    __ movl(TMP, FieldAddress(RDX, target::Object::tags_offset()));
    __ testl(TMP, Immediate(1 << target::RawObject::kCardRememberedBit));
    __ j(NOT_ZERO, &remember_card, Assembler::kFarJump);
  } else {
#if defined(DEBUG)
    Label ok;
    __ movl(TMP, FieldAddress(RDX, target::Object::tags_offset()));
    __ testl(TMP, Immediate(1 << target::RawObject::kCardRememberedBit));
    __ j(ZERO, &ok, Assembler::kFarJump);
    __ Stop("Wrong barrier");
    __ Bind(&ok);
#endif
  }

  // Update the tags that this object has been remembered.
  // Note that we use 32 bit operations here to match the size of the
  // background sweeper which is also manipulating this 32 bit word.
  // RDX: Address being stored
  // RAX: Current tag value
  // lock+andl is an atomic read-modify-write.
  __ lock();
  __ andl(FieldAddress(RDX, target::Object::tags_offset()),
          Immediate(~(1 << target::RawObject::kOldAndNotRememberedBit)));

  // Save registers being destroyed.
  __ pushq(RAX);
  __ pushq(RCX);

  // Load the StoreBuffer block out of the thread. Then load top_ out of the
  // StoreBufferBlock and add the address to the pointers_.
  // RDX: Address being stored
  __ movq(RAX, Address(THR, target::Thread::store_buffer_block_offset()));
  __ movl(RCX, Address(RAX, target::StoreBufferBlock::top_offset()));
  __ movq(
      Address(RAX, RCX, TIMES_8, target::StoreBufferBlock::pointers_offset()),
      RDX);

  // Increment top_ and check for overflow.
  // RCX: top_
  // RAX: StoreBufferBlock
  Label overflow;
  __ incq(RCX);
  __ movl(Address(RAX, target::StoreBufferBlock::top_offset()), RCX);
  __ cmpl(RCX, Immediate(target::StoreBufferBlock::kSize));
  // Restore values.
  __ popq(RCX);
  __ popq(RAX);
  __ j(EQUAL, &overflow, Assembler::kNearJump);
  __ ret();

  // Handle overflow: Call the runtime leaf function.
  __ Bind(&overflow);
  // Setup frame, push callee-saved registers.
  __ pushq(CODE_REG);
  __ movq(CODE_REG, stub_code);
  __ EnterCallRuntimeFrame(0);
  __ movq(CallingConventions::kArg1Reg, THR);
  __ CallRuntime(kStoreBufferBlockProcessRuntimeEntry, 1);
  __ LeaveCallRuntimeFrame();
  __ popq(CODE_REG);
  __ ret();

  __ Bind(&add_to_mark_stack);
  __ pushq(RAX);      // Spill.
  __ pushq(RCX);      // Spill.
  __ movq(TMP, RAX);  // RAX is fixed implicit operand of CAS.

  // Atomically clear kOldAndNotMarkedBit.
  // Note that we use 32 bit operations here to match the size of the
  // background marker which is also manipulating this 32 bit word.
  Label retry, lost_race, marking_overflow;
  __ movl(RAX, FieldAddress(TMP, target::Object::tags_offset()));
  __ Bind(&retry);
  __ movl(RCX, RAX);
  __ testl(RCX, Immediate(1 << target::RawObject::kOldAndNotMarkedBit));
  __ j(ZERO, &lost_race);  // Marked by another thread.
  __ andl(RCX, Immediate(~(1 << target::RawObject::kOldAndNotMarkedBit)));
  __ LockCmpxchgl(FieldAddress(TMP, target::Object::tags_offset()), RCX);
  __ j(NOT_EQUAL, &retry, Assembler::kNearJump);

  __ movq(RAX, Address(THR, target::Thread::marking_stack_block_offset()));
  __ movl(RCX, Address(RAX, target::MarkingStackBlock::top_offset()));
  __ movq(
      Address(RAX, RCX, TIMES_8, target::MarkingStackBlock::pointers_offset()),
      TMP);
  __ incq(RCX);
  __ movl(Address(RAX, target::MarkingStackBlock::top_offset()), RCX);
  __ cmpl(RCX, Immediate(target::MarkingStackBlock::kSize));
  __ popq(RCX);  // Unspill.
  __ popq(RAX);  // Unspill.
  __ j(EQUAL, &marking_overflow, Assembler::kNearJump);
  __ ret();

  __ Bind(&marking_overflow);
  __ pushq(CODE_REG);
  __ movq(CODE_REG, stub_code);
  __ EnterCallRuntimeFrame(0);
  __ movq(CallingConventions::kArg1Reg, THR);
  __ CallRuntime(kMarkingStackBlockProcessRuntimeEntry, 1);
  __ LeaveCallRuntimeFrame();
  __ popq(CODE_REG);
  __ ret();

  __ Bind(&lost_race);
  __ popq(RCX);  // Unspill.
  __ popq(RAX);  // Unspill.
  __ ret();

  if (cards) {
    Label remember_card_slow;

    // Get card table.
    __ Bind(&remember_card);
    __ movq(TMP, RDX);                           // Object.
    __ andq(TMP, Immediate(target::kPageMask));  // HeapPage.
    __ cmpq(Address(TMP, target::HeapPage::card_table_offset()), Immediate(0));
    __ j(EQUAL, &remember_card_slow, Assembler::kNearJump);

    // Dirty the card.
    __ subq(R13, TMP);  // Offset in page.
    __ movq(
        TMP,
        Address(TMP, target::HeapPage::card_table_offset()));  // Card table.
    __ shrq(R13,
            Immediate(
                target::HeapPage::kBytesPerCardLog2));  // Index in card table.
    __ movb(Address(TMP, R13, TIMES_1, 0), Immediate(1));
    __ ret();

    // Card table not yet allocated.
    __ Bind(&remember_card_slow);
    __ pushq(CODE_REG);
    __ movq(CODE_REG, stub_code);
    __ EnterCallRuntimeFrame(0);
    __ movq(CallingConventions::kArg1Reg, RDX);
    __ movq(CallingConventions::kArg2Reg, R13);
    __ CallRuntime(kRememberCardRuntimeEntry, 2);
    __ LeaveCallRuntimeFrame();
    __ popq(CODE_REG);
    __ ret();
  }
}

void StubCodeCompiler::GenerateWriteBarrierStub(Assembler* assembler) {
  GenerateWriteBarrierStubHelper(
      assembler, Address(THR, target::Thread::write_barrier_code_offset()),
      false);
}

void StubCodeCompiler::GenerateArrayWriteBarrierStub(Assembler* assembler) {
  GenerateWriteBarrierStubHelper(
      assembler,
      Address(THR, target::Thread::array_write_barrier_code_offset()), true);
}

// Called for inline allocation of objects.
// Input parameters:
//   RSP + 8 : type arguments object (only if class is parameterized).
//   RSP : points to return address.
void StubCodeCompiler::GenerateAllocationStubForClass(Assembler* assembler,
                                                      const Class& cls) {
  const intptr_t kObjectTypeArgumentsOffset = 1 * target::kWordSize;
  // The generated code is different if the class is parameterized.
  const bool is_cls_parameterized = target::Class::NumTypeArguments(cls) > 0;
  ASSERT(!is_cls_parameterized || target::Class::TypeArgumentsFieldOffset(
                                      cls) != target::Class::kNoTypeArguments);
  // kInlineInstanceSize is a constant used as a threshold for determining
  // when the object initialization should be done as a loop or as
  // straight line code.
  const int kInlineInstanceSize = 12;  // In words.
  const intptr_t instance_size = target::Class::GetInstanceSize(cls);
  ASSERT(instance_size > 0);
  __ LoadObject(R9, NullObject());
  if (is_cls_parameterized) {
    __ movq(RDX, Address(RSP, kObjectTypeArgumentsOffset));
    // RDX: instantiated type arguments.
  }
  if (FLAG_inline_alloc &&
      target::Heap::IsAllocatableInNewSpace(instance_size) &&
      !target::Class::TraceAllocation(cls)) {
    Label slow_case;
    // Allocate the object and update top to point to
    // next object start and initialize the allocated object.
    // RDX: instantiated type arguments (if is_cls_parameterized).
    __ movq(RAX, Address(THR, target::Thread::top_offset()));
    __ leaq(RBX, Address(RAX, instance_size));
    // Check if the allocation fits into the remaining space.
    // RAX: potential new object start.
    // RBX: potential next object start.
    __ cmpq(RBX, Address(THR, target::Thread::end_offset()));
    if (FLAG_use_slow_path) {
      __ jmp(&slow_case);
    } else {
      __ j(ABOVE_EQUAL, &slow_case);
    }
    __ movq(Address(THR, target::Thread::top_offset()), RBX);
    NOT_IN_PRODUCT(__ UpdateAllocationStats(target::Class::GetId(cls)));

    // RAX: new object start (untagged).
    // RBX: next object start.
    // RDX: new object type arguments (if is_cls_parameterized).
    // Set the tags.
    ASSERT(target::Class::GetId(cls) != kIllegalCid);
    const uint32_t tags = target::MakeTagWordForNewSpaceObject(
        target::Class::GetId(cls), instance_size);
    // 64 bit store also zeros the identity hash field.
    __ movq(Address(RAX, target::Object::tags_offset()), Immediate(tags));
    __ addq(RAX, Immediate(kHeapObjectTag));

    // Initialize the remaining words of the object.
    // RAX: new object (tagged).
    // RBX: next object start.
    // RDX: new object type arguments (if is_cls_parameterized).
    // R9: raw null.
    // First try inlining the initialization without a loop.
    if (instance_size < (kInlineInstanceSize * target::kWordSize)) {
      // Check if the object contains any non-header fields.
      // Small objects are initialized using a consecutive set of writes.
      for (intptr_t current_offset = target::Instance::first_field_offset();
           current_offset < instance_size;
           current_offset += target::kWordSize) {
        __ StoreIntoObjectNoBarrier(RAX, FieldAddress(RAX, current_offset), R9);
      }
    } else {
      __ leaq(RCX, FieldAddress(RAX, target::Instance::first_field_offset()));
      // Loop until the whole object is initialized.
      // RAX: new object (tagged).
      // RBX: next object start.
      // RCX: next word to be initialized.
      // RDX: new object type arguments (if is_cls_parameterized).
      Label init_loop;
      Label done;
      __ Bind(&init_loop);
      __ cmpq(RCX, RBX);
#if defined(DEBUG)
      static const bool kJumpLength = Assembler::kFarJump;
#else
      static const bool kJumpLength = Assembler::kNearJump;
#endif  // DEBUG
      __ j(ABOVE_EQUAL, &done, kJumpLength);
      __ StoreIntoObjectNoBarrier(RAX, Address(RCX, 0), R9);
      __ addq(RCX, Immediate(target::kWordSize));
      __ jmp(&init_loop, Assembler::kNearJump);
      __ Bind(&done);
    }
    if (is_cls_parameterized) {
      // RAX: new object (tagged).
      // RDX: new object type arguments.
      // Set the type arguments in the new object.
      const intptr_t offset = target::Class::TypeArgumentsFieldOffset(cls);
      __ StoreIntoObjectNoBarrier(RAX, FieldAddress(RAX, offset), RDX);
    }
    // Done allocating and initializing the instance.
    // RAX: new object (tagged).
    __ ret();

    __ Bind(&slow_case);
  }
  // If is_cls_parameterized:
  // RDX: new object type arguments.
  // Create a stub frame.
  __ EnterStubFrame();  // Uses PP to access class object.

  __ pushq(R9);  // Setup space on stack for return value.
  __ PushObject(
      CastHandle<Object>(cls));  // Push class of object to be allocated.
  if (is_cls_parameterized) {
    __ pushq(RDX);  // Push type arguments of object to be allocated.
  } else {
    __ pushq(R9);  // Push null type arguments.
  }
  __ CallRuntime(kAllocateObjectRuntimeEntry, 2);  // Allocate object.
  __ popq(RAX);  // Pop argument (type arguments of object).
  __ popq(RAX);  // Pop argument (class of object).
  __ popq(RAX);  // Pop result (newly allocated object).

  if (AllocateObjectInstr::WillAllocateNewOrRemembered(cls)) {
    // Write-barrier elimination is enabled for [cls] and we therefore need to
    // ensure that the object is in new-space or has remembered bit set.
    EnsureIsNewOrRemembered(assembler, /*preserve_registers=*/false);
  }

  // RAX: new object
  // Restore the frame pointer.
  __ LeaveStubFrame();
  __ ret();
}

// Called for invoking "dynamic noSuchMethod(Invocation invocation)" function
// from the entry code of a dart function after an error in passed argument
// name or number is detected.
// Input parameters:
//   RSP : points to return address.
//   RSP + 8 : address of last argument.
//   R10 : arguments descriptor array.
void StubCodeCompiler::GenerateCallClosureNoSuchMethodStub(
    Assembler* assembler) {
  __ EnterStubFrame();

  // Load the receiver.
  __ movq(R13, FieldAddress(R10, target::ArgumentsDescriptor::count_offset()));
  __ movq(RAX,
          Address(RBP, R13, TIMES_4,
                  target::frame_layout.param_end_from_fp * target::kWordSize));

  // Load the function.
  __ movq(RBX, FieldAddress(RAX, target::Closure::function_offset()));

  __ pushq(Immediate(0));  // Result slot.
  __ pushq(RAX);           // Receiver.
  __ pushq(RBX);           // Function.
  __ pushq(R10);           // Arguments descriptor array.

  // Adjust arguments count.
  __ cmpq(
      FieldAddress(R10, target::ArgumentsDescriptor::type_args_len_offset()),
      Immediate(0));
  __ movq(R10, R13);
  Label args_count_ok;
  __ j(EQUAL, &args_count_ok, Assembler::kNearJump);
  __ addq(R10, Immediate(target::ToRawSmi(1)));  // Include the type arguments.
  __ Bind(&args_count_ok);

  // R10: Smi-tagged arguments array length.
  PushArrayOfArguments(assembler);

  const intptr_t kNumArgs = 4;
  __ CallRuntime(kNoSuchMethodFromPrologueRuntimeEntry, kNumArgs);
  // noSuchMethod on closures always throws an error, so it will never return.
  __ int3();
}

// Cannot use function object from ICData as it may be the inlined
// function and not the top-scope function.
void StubCodeCompiler::GenerateOptimizedUsageCounterIncrement(
    Assembler* assembler) {
  Register ic_reg = RBX;
  Register func_reg = RDI;
  if (FLAG_trace_optimized_ic_calls) {
    __ EnterStubFrame();
    __ pushq(func_reg);  // Preserve
    __ pushq(ic_reg);    // Preserve.
    __ pushq(ic_reg);    // Argument.
    __ pushq(func_reg);  // Argument.
    __ CallRuntime(kTraceICCallRuntimeEntry, 2);
    __ popq(RAX);       // Discard argument;
    __ popq(RAX);       // Discard argument;
    __ popq(ic_reg);    // Restore.
    __ popq(func_reg);  // Restore.
    __ LeaveStubFrame();
  }
  __ incl(FieldAddress(func_reg, target::Function::usage_counter_offset()));
}

// Loads function into 'temp_reg', preserves 'ic_reg'.
void StubCodeCompiler::GenerateUsageCounterIncrement(Assembler* assembler,
                                                     Register temp_reg) {
  if (FLAG_optimization_counter_threshold >= 0) {
    Register ic_reg = RBX;
    Register func_reg = temp_reg;
    ASSERT(ic_reg != func_reg);
    __ Comment("Increment function counter");
    __ movq(func_reg, FieldAddress(ic_reg, target::ICData::owner_offset()));
    __ incl(FieldAddress(func_reg, target::Function::usage_counter_offset()));
  }
}

// Note: RBX must be preserved.
// Attempt a quick Smi operation for known operations ('kind'). The ICData
// must have been primed with a Smi/Smi check that will be used for counting
// the invocations.
static void EmitFastSmiOp(Assembler* assembler,
                          Token::Kind kind,
                          intptr_t num_args,
                          Label* not_smi_or_overflow) {
  __ Comment("Fast Smi op");
  ASSERT(num_args == 2);
  __ movq(RAX, Address(RSP, +2 * target::kWordSize));  // Left.
  __ movq(RCX, Address(RSP, +1 * target::kWordSize));  // Right
  __ movq(R13, RCX);
  __ orq(R13, RAX);
  __ testq(R13, Immediate(kSmiTagMask));
  __ j(NOT_ZERO, not_smi_or_overflow);
  switch (kind) {
    case Token::kADD: {
      __ addq(RAX, RCX);
      __ j(OVERFLOW, not_smi_or_overflow);
      break;
    }
    case Token::kLT: {
      __ cmpq(RAX, RCX);
      __ setcc(GREATER_EQUAL, ByteRegisterOf(RAX));
      __ movzxb(RAX, RAX);  // RAX := RAX < RCX ? 0 : 1
      __ movq(RAX,
              Address(THR, RAX, TIMES_8, target::Thread::bool_true_offset()));
      ASSERT(target::Thread::bool_true_offset() + 8 ==
             target::Thread::bool_false_offset());
      break;
    }
    case Token::kEQ: {
      __ cmpq(RAX, RCX);
      __ setcc(NOT_EQUAL, ByteRegisterOf(RAX));
      __ movzxb(RAX, RAX);  // RAX := RAX == RCX ? 0 : 1
      __ movq(RAX,
              Address(THR, RAX, TIMES_8, target::Thread::bool_true_offset()));
      ASSERT(target::Thread::bool_true_offset() + 8 ==
             target::Thread::bool_false_offset());
      break;
    }
    default:
      UNIMPLEMENTED();
  }

  // RBX: IC data object (preserved).
  __ movq(R13, FieldAddress(RBX, target::ICData::entries_offset()));
  // R13: ic_data_array with check entries: classes and target functions.
  __ leaq(R13, FieldAddress(R13, target::Array::data_offset()));
// R13: points directly to the first ic data array element.
#if defined(DEBUG)
  // Check that first entry is for Smi/Smi.
  Label error, ok;
  const Immediate& imm_smi_cid = Immediate(target::ToRawSmi(kSmiCid));
  __ cmpq(Address(R13, 0 * target::kWordSize), imm_smi_cid);
  __ j(NOT_EQUAL, &error, Assembler::kNearJump);
  __ cmpq(Address(R13, 1 * target::kWordSize), imm_smi_cid);
  __ j(EQUAL, &ok, Assembler::kNearJump);
  __ Bind(&error);
  __ Stop("Incorrect IC data");
  __ Bind(&ok);
#endif

  if (FLAG_optimization_counter_threshold >= 0) {
    const intptr_t count_offset =
        target::ICData::CountIndexFor(num_args) * target::kWordSize;
    // Update counter, ignore overflow.
    __ addq(Address(R13, count_offset), Immediate(target::ToRawSmi(1)));
  }

  __ ret();
}

// Generate inline cache check for 'num_args'.
//  RDX: receiver (if instance call)
//  RBX: ICData
//  RSP[0]: return address
// Control flow:
// - If receiver is null -> jump to IC miss.
// - If receiver is Smi -> load Smi class.
// - If receiver is not-Smi -> load receiver's class.
// - Check if 'num_args' (including receiver) match any IC data group.
// - Match found -> jump to target.
// - Match not found -> jump to IC miss.
void StubCodeCompiler::GenerateNArgsCheckInlineCacheStub(
    Assembler* assembler,
    intptr_t num_args,
    const RuntimeEntry& handle_ic_miss,
    Token::Kind kind,
    Optimized optimized,
    CallType type,
    Exactness exactness) {
  ASSERT(num_args == 1 || num_args == 2);
#if defined(DEBUG)
  {
    Label ok;
    // Check that the IC data array has NumArgsTested() == num_args.
    // 'NumArgsTested' is stored in the least significant bits of 'state_bits'.
    __ movl(RCX, FieldAddress(RBX, target::ICData::state_bits_offset()));
    ASSERT(target::ICData::NumArgsTestedShift() == 0);  // No shift needed.
    __ andq(RCX, Immediate(target::ICData::NumArgsTestedMask()));
    __ cmpq(RCX, Immediate(num_args));
    __ j(EQUAL, &ok, Assembler::kNearJump);
    __ Stop("Incorrect stub for IC data");
    __ Bind(&ok);
  }
#endif  // DEBUG

#if !defined(PRODUCT)
  Label stepping, done_stepping;
  if (optimized == kUnoptimized) {
    __ Comment("Check single stepping");
    __ LoadIsolate(RAX);
    __ cmpb(Address(RAX, target::Isolate::single_step_offset()), Immediate(0));
    __ j(NOT_EQUAL, &stepping);
    __ Bind(&done_stepping);
  }
#endif

  Label not_smi_or_overflow;
  if (kind != Token::kILLEGAL) {
    EmitFastSmiOp(assembler, kind, num_args, &not_smi_or_overflow);
  }
  __ Bind(&not_smi_or_overflow);

  __ Comment("Extract ICData initial values and receiver cid");
  // RBX: IC data object (preserved).
  __ movq(R13, FieldAddress(RBX, target::ICData::entries_offset()));
  // R13: ic_data_array with check entries: classes and target functions.
  __ leaq(R13, FieldAddress(R13, target::Array::data_offset()));
  // R13: points directly to the first ic data array element.

  if (type == kInstanceCall) {
    __ LoadTaggedClassIdMayBeSmi(RAX, RDX);
    __ movq(R10,
            FieldAddress(RBX, target::ICData::arguments_descriptor_offset()));
    if (num_args == 2) {
      __ movq(RCX,
              FieldAddress(R10, target::ArgumentsDescriptor::count_offset()));
      __ movq(R9, Address(RSP, RCX, TIMES_4, -target::kWordSize));
      __ LoadTaggedClassIdMayBeSmi(RCX, R9);
    }
  } else {
    __ movq(R10,
            FieldAddress(RBX, target::ICData::arguments_descriptor_offset()));
    __ movq(RCX,
            FieldAddress(R10, target::ArgumentsDescriptor::count_offset()));
    __ movq(RDX, Address(RSP, RCX, TIMES_4, 0));
    __ LoadTaggedClassIdMayBeSmi(RAX, RDX);
    if (num_args == 2) {
      __ movq(R9, Address(RSP, RCX, TIMES_4, -target::kWordSize));
      __ LoadTaggedClassIdMayBeSmi(RCX, R9);
    }
  }
  // RAX: first argument class ID as Smi.
  // RCX: second argument class ID as Smi.
  // R10: args descriptor

  // Loop that checks if there is an IC data match.
  Label loop, found, miss;
  __ Comment("ICData loop");

  // We unroll the generic one that is generated once more than the others.
  const bool optimize = kind == Token::kILLEGAL;
  const intptr_t target_offset =
      target::ICData::TargetIndexFor(num_args) * target::kWordSize;
  const intptr_t count_offset =
      target::ICData::CountIndexFor(num_args) * target::kWordSize;
  const intptr_t exactness_offset =
      target::ICData::ExactnessIndexFor(num_args) * target::kWordSize;

  __ Bind(&loop);
  for (int unroll = optimize ? 4 : 2; unroll >= 0; unroll--) {
    Label update;
    __ movq(R9, Address(R13, 0));
    __ cmpq(RAX, R9);  // Class id match?
    if (num_args == 2) {
      __ j(NOT_EQUAL, &update);  // Continue.
      __ movq(R9, Address(R13, target::kWordSize));
      // R9: next class ID to check (smi).
      __ cmpq(RCX, R9);  // Class id match?
    }
    __ j(EQUAL, &found);  // Break.

    __ Bind(&update);

    const intptr_t entry_size = target::ICData::TestEntryLengthFor(
                                    num_args, exactness == kCheckExactness) *
                                target::kWordSize;
    __ addq(R13, Immediate(entry_size));  // Next entry.

    __ cmpq(R9, Immediate(target::ToRawSmi(kIllegalCid)));  // Done?
    if (unroll == 0) {
      __ j(NOT_EQUAL, &loop);
    } else {
      __ j(EQUAL, &miss);
    }
  }

  __ Bind(&miss);
  __ Comment("IC miss");
  // Compute address of arguments (first read number of arguments from
  // arguments descriptor array and then compute address on the stack).
  __ movq(RAX, FieldAddress(R10, target::ArgumentsDescriptor::count_offset()));
  __ leaq(RAX, Address(RSP, RAX, TIMES_4, 0));  // RAX is Smi.
  __ EnterStubFrame();
  __ pushq(R10);           // Preserve arguments descriptor array.
  __ pushq(RBX);           // Preserve IC data object.
  __ pushq(Immediate(0));  // Result slot.
  // Push call arguments.
  for (intptr_t i = 0; i < num_args; i++) {
    __ movq(RCX, Address(RAX, -target::kWordSize * i));
    __ pushq(RCX);
  }
  __ pushq(RBX);  // Pass IC data object.
  __ CallRuntime(handle_ic_miss, num_args + 1);
  // Remove the call arguments pushed earlier, including the IC data object.
  for (intptr_t i = 0; i < num_args + 1; i++) {
    __ popq(RAX);
  }
  __ popq(RAX);  // Pop returned function object into RAX.
  __ popq(RBX);  // Restore IC data array.
  __ popq(R10);  // Restore arguments descriptor array.
  __ RestoreCodePointer();
  __ LeaveStubFrame();
  Label call_target_function;
  if (!FLAG_lazy_dispatchers) {
    GenerateDispatcherCode(assembler, &call_target_function);
  } else {
    __ jmp(&call_target_function);
  }

  __ Bind(&found);
  // R13: Pointer to an IC data check group.
  Label call_target_function_through_unchecked_entry;
  if (exactness == kCheckExactness) {
    Label exactness_ok;
    ASSERT(num_args == 1);
    __ movq(RAX, Address(R13, exactness_offset));
    __ cmpq(RAX, Immediate(target::ToRawSmi(
                     StaticTypeExactnessState::HasExactSuperType().Encode())));
    __ j(LESS, &exactness_ok);
    __ j(EQUAL, &call_target_function_through_unchecked_entry);

    // Check trivial exactness.
    // Note: RawICData::receivers_static_type_ is guaranteed to be not null
    // because we only emit calls to this stub when it is not null.
    __ movq(RCX,
            FieldAddress(RBX, target::ICData::receivers_static_type_offset()));
    __ movq(RCX, FieldAddress(RCX, target::Type::arguments_offset()));
    // RAX contains an offset to type arguments in words as a smi,
    // hence TIMES_4. RDX is guaranteed to be non-smi because it is expected to
    // have type arguments.
    __ cmpq(RCX, FieldAddress(RDX, RAX, TIMES_4, 0));
    __ j(EQUAL, &call_target_function_through_unchecked_entry);

    // Update exactness state (not-exact anymore).
    __ movq(Address(R13, exactness_offset),
            Immediate(target::ToRawSmi(
                StaticTypeExactnessState::NotExact().Encode())));
    __ Bind(&exactness_ok);
  }
  __ movq(RAX, Address(R13, target_offset));

  if (FLAG_optimization_counter_threshold >= 0) {
    __ Comment("Update ICData counter");
    // Ignore overflow.
    __ addq(Address(R13, count_offset), Immediate(target::ToRawSmi(1)));
  }

  __ Comment("Call target (via checked entry point)");
  __ Bind(&call_target_function);
  // RAX: Target function.
  __ movq(CODE_REG, FieldAddress(RAX, target::Function::code_offset()));
  __ jmp(FieldAddress(RAX, target::Function::entry_point_offset()));

  if (exactness == kCheckExactness) {
    __ Bind(&call_target_function_through_unchecked_entry);
    if (FLAG_optimization_counter_threshold >= 0) {
      __ Comment("Update ICData counter");
      // Ignore overflow.
      __ addq(Address(R13, count_offset), Immediate(target::ToRawSmi(1)));
    }
    __ Comment("Call target (via unchecked entry point)");
    __ movq(RAX, Address(R13, target_offset));
    __ movq(CODE_REG, FieldAddress(RAX, target::Function::code_offset()));
    __ jmp(FieldAddress(RAX, target::Function::unchecked_entry_point_offset()));
  }

#if !defined(PRODUCT)
  if (optimized == kUnoptimized) {
    __ Bind(&stepping);
    __ EnterStubFrame();
    if (type == kInstanceCall) {
      __ pushq(RDX);  // Preserve receiver.
    }
    __ pushq(RBX);  // Preserve ICData.
    __ CallRuntime(kSingleStepHandlerRuntimeEntry, 0);
    __ popq(RBX);  // Restore ICData.
    if (type == kInstanceCall) {
      __ popq(RDX);  // Restore receiver.
    }
    __ RestoreCodePointer();
    __ LeaveStubFrame();
    __ jmp(&done_stepping);
  }
#endif
}

//  RDX: receiver
//  RBX: ICData
//  RSP[0]: return address
void StubCodeCompiler::GenerateOneArgCheckInlineCacheStub(
    Assembler* assembler) {
  GenerateUsageCounterIncrement(assembler, /* scratch */ RCX);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 1, kInlineCacheMissHandlerOneArgRuntimeEntry, Token::kILLEGAL,
      kUnoptimized, kInstanceCall, kIgnoreExactness);
}

//  RDX: receiver
//  RBX: ICData
//  RSP[0]: return address
void StubCodeCompiler::GenerateOneArgCheckInlineCacheWithExactnessCheckStub(
    Assembler* assembler) {
  GenerateUsageCounterIncrement(assembler, /* scratch */ RCX);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 1, kInlineCacheMissHandlerOneArgRuntimeEntry, Token::kILLEGAL,
      kUnoptimized, kInstanceCall, kCheckExactness);
}

//  RDX: receiver
//  RBX: ICData
//  RSP[0]: return address
void StubCodeCompiler::GenerateTwoArgsCheckInlineCacheStub(
    Assembler* assembler) {
  GenerateUsageCounterIncrement(assembler, /* scratch */ RCX);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 2, kInlineCacheMissHandlerTwoArgsRuntimeEntry, Token::kILLEGAL,
      kUnoptimized, kInstanceCall, kIgnoreExactness);
}

//  RDX: receiver
//  RBX: ICData
//  RSP[0]: return address
void StubCodeCompiler::GenerateSmiAddInlineCacheStub(Assembler* assembler) {
  GenerateUsageCounterIncrement(assembler, /* scratch */ RCX);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 2, kInlineCacheMissHandlerTwoArgsRuntimeEntry, Token::kADD,
      kUnoptimized, kInstanceCall, kIgnoreExactness);
}

//  RDX: receiver
//  RBX: ICData
//  RSP[0]: return address
void StubCodeCompiler::GenerateSmiLessInlineCacheStub(Assembler* assembler) {
  GenerateUsageCounterIncrement(assembler, /* scratch */ RCX);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 2, kInlineCacheMissHandlerTwoArgsRuntimeEntry, Token::kLT,
      kUnoptimized, kInstanceCall, kIgnoreExactness);
}

//  RDX: receiver
//  RBX: ICData
//  RSP[0]: return address
void StubCodeCompiler::GenerateSmiEqualInlineCacheStub(Assembler* assembler) {
  GenerateUsageCounterIncrement(assembler, /* scratch */ RCX);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 2, kInlineCacheMissHandlerTwoArgsRuntimeEntry, Token::kEQ,
      kUnoptimized, kInstanceCall, kIgnoreExactness);
}

//  RDX: receiver
//  RBX: ICData
//  RDI: Function
//  RSP[0]: return address
void StubCodeCompiler::GenerateOneArgOptimizedCheckInlineCacheStub(
    Assembler* assembler) {
  GenerateOptimizedUsageCounterIncrement(assembler);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 1, kInlineCacheMissHandlerOneArgRuntimeEntry, Token::kILLEGAL,
      kOptimized, kInstanceCall, kIgnoreExactness);
}

//  RDX: receiver
//  RBX: ICData
//  RDI: Function
//  RSP[0]: return address
void StubCodeCompiler::
    GenerateOneArgOptimizedCheckInlineCacheWithExactnessCheckStub(
        Assembler* assembler) {
  GenerateOptimizedUsageCounterIncrement(assembler);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 1, kInlineCacheMissHandlerOneArgRuntimeEntry, Token::kILLEGAL,
      kOptimized, kInstanceCall, kCheckExactness);
}

//  RDX: receiver
//  RBX: ICData
//  RDI: Function
//  RSP[0]: return address
void StubCodeCompiler::GenerateTwoArgsOptimizedCheckInlineCacheStub(
    Assembler* assembler) {
  GenerateOptimizedUsageCounterIncrement(assembler);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 2, kInlineCacheMissHandlerTwoArgsRuntimeEntry, Token::kILLEGAL,
      kOptimized, kInstanceCall, kIgnoreExactness);
}

//  RBX: ICData
//  RSP[0]: return address
void StubCodeCompiler::GenerateZeroArgsUnoptimizedStaticCallStub(
    Assembler* assembler) {
  GenerateUsageCounterIncrement(assembler, /* scratch */ RCX);
#if defined(DEBUG)
  {
    Label ok;
    // Check that the IC data array has NumArgsTested() == 0.
    // 'NumArgsTested' is stored in the least significant bits of 'state_bits'.
    __ movl(RCX, FieldAddress(RBX, target::ICData::state_bits_offset()));
    ASSERT(target::ICData::NumArgsTestedShift() == 0);  // No shift needed.
    __ andq(RCX, Immediate(target::ICData::NumArgsTestedMask()));
    __ cmpq(RCX, Immediate(0));
    __ j(EQUAL, &ok, Assembler::kNearJump);
    __ Stop("Incorrect IC data for unoptimized static call");
    __ Bind(&ok);
  }
#endif  // DEBUG

#if !defined(PRODUCT)
  // Check single stepping.
  Label stepping, done_stepping;
  __ LoadIsolate(RAX);
  __ movzxb(RAX, Address(RAX, target::Isolate::single_step_offset()));
  __ cmpq(RAX, Immediate(0));
#if defined(DEBUG)
  static const bool kJumpLength = Assembler::kFarJump;
#else
  static const bool kJumpLength = Assembler::kNearJump;
#endif  // DEBUG
  __ j(NOT_EQUAL, &stepping, kJumpLength);
  __ Bind(&done_stepping);
#endif

  // RBX: IC data object (preserved).
  __ movq(R12, FieldAddress(RBX, target::ICData::entries_offset()));
  // R12: ic_data_array with entries: target functions and count.
  __ leaq(R12, FieldAddress(R12, target::Array::data_offset()));
  // R12: points directly to the first ic data array element.
  const intptr_t target_offset =
      target::ICData::TargetIndexFor(0) * target::kWordSize;
  const intptr_t count_offset =
      target::ICData::CountIndexFor(0) * target::kWordSize;

  if (FLAG_optimization_counter_threshold >= 0) {
    // Increment count for this call, ignore overflow.
    __ addq(Address(R12, count_offset), Immediate(target::ToRawSmi(1)));
  }

  // Load arguments descriptor into R10.
  __ movq(R10,
          FieldAddress(RBX, target::ICData::arguments_descriptor_offset()));

  // Get function and call it, if possible.
  __ movq(RAX, Address(R12, target_offset));
  __ movq(CODE_REG, FieldAddress(RAX, target::Function::code_offset()));
  __ movq(RCX, FieldAddress(RAX, target::Function::entry_point_offset()));
  __ jmp(RCX);

#if !defined(PRODUCT)
  __ Bind(&stepping);
  __ EnterStubFrame();
  __ pushq(RBX);  // Preserve IC data object.
  __ CallRuntime(kSingleStepHandlerRuntimeEntry, 0);
  __ popq(RBX);
  __ RestoreCodePointer();
  __ LeaveStubFrame();
  __ jmp(&done_stepping, Assembler::kNearJump);
#endif
}

//  RBX: ICData
//  RSP[0]: return address
void StubCodeCompiler::GenerateOneArgUnoptimizedStaticCallStub(
    Assembler* assembler) {
  GenerateUsageCounterIncrement(assembler, /* scratch */ RCX);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 1, kStaticCallMissHandlerOneArgRuntimeEntry, Token::kILLEGAL,
      kUnoptimized, kStaticCall, kIgnoreExactness);
}

//  RBX: ICData
//  RSP[0]: return address
void StubCodeCompiler::GenerateTwoArgsUnoptimizedStaticCallStub(
    Assembler* assembler) {
  GenerateUsageCounterIncrement(assembler, /* scratch */ RCX);
  GenerateNArgsCheckInlineCacheStub(
      assembler, 2, kStaticCallMissHandlerTwoArgsRuntimeEntry, Token::kILLEGAL,
      kUnoptimized, kStaticCall, kIgnoreExactness);
}

// Stub for compiling a function and jumping to the compiled code.
// R10: Arguments descriptor.
// RAX: Function.
void StubCodeCompiler::GenerateLazyCompileStub(Assembler* assembler) {
  __ EnterStubFrame();
  __ pushq(R10);  // Preserve arguments descriptor array.
  __ pushq(RAX);  // Pass function.
  __ CallRuntime(kCompileFunctionRuntimeEntry, 1);
  __ popq(RAX);  // Restore function.
  __ popq(R10);  // Restore arguments descriptor array.
  __ LeaveStubFrame();

  // When using the interpreter, the function's code may now point to the
  // InterpretCall stub. Make sure RAX, R10, and RBX are preserved.
  __ movq(CODE_REG, FieldAddress(RAX, target::Function::code_offset()));
  __ movq(RCX, FieldAddress(RAX, target::Function::entry_point_offset()));
  __ jmp(RCX);
}

// Stub for interpreting a function call.
// R10: Arguments descriptor.
// RAX: Function.
void StubCodeCompiler::GenerateInterpretCallStub(Assembler* assembler) {
#if defined(DART_PRECOMPILED_RUNTIME)
  __ Stop("Not using interpreter");
#else
  __ EnterStubFrame();

#if defined(DEBUG)
  {
    Label ok;
    // Check that we are always entering from Dart code.
    __ movq(R8, Immediate(VMTag::kDartCompiledTagId));
    __ cmpq(R8, Assembler::VMTagAddress());
    __ j(EQUAL, &ok, Assembler::kNearJump);
    __ Stop("Not coming from Dart code.");
    __ Bind(&ok);
  }
#endif

  // Adjust arguments count for type arguments vector.
  __ movq(R11, FieldAddress(R10, target::ArgumentsDescriptor::count_offset()));
  __ SmiUntag(R11);
  __ cmpq(
      FieldAddress(R10, target::ArgumentsDescriptor::type_args_len_offset()),
      Immediate(0));
  Label args_count_ok;
  __ j(EQUAL, &args_count_ok, Assembler::kNearJump);
  __ incq(R11);
  __ Bind(&args_count_ok);

  // Compute argv.
  __ leaq(R12,
          Address(RBP, R11, TIMES_8,
                  target::frame_layout.param_end_from_fp * target::kWordSize));

  // Indicate decreasing memory addresses of arguments with negative argc.
  __ negq(R11);

  // Reserve shadow space for args and align frame before entering C++ world.
  __ subq(RSP, Immediate(5 * target::kWordSize));
  if (OS::ActivationFrameAlignment() > 1) {
    __ andq(RSP, Immediate(~(OS::ActivationFrameAlignment() - 1)));
  }

  __ movq(CallingConventions::kArg1Reg, RAX);         // Function.
  __ movq(CallingConventions::kArg2Reg, R10);         // Arguments descriptor.
  __ movq(CallingConventions::kArg3Reg, R11);         // Negative argc.
  __ movq(CallingConventions::kArg4Reg, R12);         // Argv.

#if defined(_WIN64)
  __ movq(Address(RSP, 0 * target::kWordSize), THR);  // Thread.
#else
  __ movq(CallingConventions::kArg5Reg, THR);  // Thread.
#endif
  // Save exit frame information to enable stack walking as we are about
  // to transition to Dart VM C++ code.
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()), RBP);

  // Mark that the thread is executing VM code.
  __ movq(RAX,
          Address(THR, target::Thread::interpret_call_entry_point_offset()));
  __ movq(Assembler::VMTagAddress(), RAX);

  __ call(RAX);

  // Mark that the thread is executing Dart code.
  __ movq(Assembler::VMTagAddress(), Immediate(VMTag::kDartCompiledTagId));

  // Reset exit frame information in Isolate structure.
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()),
          Immediate(0));

  __ LeaveStubFrame();
  __ ret();
#endif  // defined(DART_PRECOMPILED_RUNTIME)
}

// RBX: Contains an ICData.
// TOS(0): return address (Dart code).
void StubCodeCompiler::GenerateICCallBreakpointStub(Assembler* assembler) {
#if defined(PRODUCT)
  __ Stop("No debugging in PRODUCT mode");
#else
  __ EnterStubFrame();
  __ pushq(RDX);           // Preserve receiver.
  __ pushq(RBX);           // Preserve IC data.
  __ pushq(Immediate(0));  // Result slot.
  __ CallRuntime(kBreakpointRuntimeHandlerRuntimeEntry, 0);
  __ popq(CODE_REG);  // Original stub.
  __ popq(RBX);       // Restore IC data.
  __ popq(RDX);       // Restore receiver.
  __ LeaveStubFrame();

  __ movq(RAX, FieldAddress(CODE_REG, target::Code::entry_point_offset()));
  __ jmp(RAX);  // Jump to original stub.
#endif  // defined(PRODUCT)
}

void StubCodeCompiler::GenerateUnoptStaticCallBreakpointStub(
    Assembler* assembler) {
#if defined(PRODUCT)
  __ Stop("No debugging in PRODUCT mode");
#else
  __ EnterStubFrame();
  __ pushq(RDX);           // Preserve receiver.
  __ pushq(RBX);           // Preserve IC data.
  __ pushq(Immediate(0));  // Result slot.
  __ CallRuntime(kBreakpointRuntimeHandlerRuntimeEntry, 0);
  __ popq(CODE_REG);  // Original stub.
  __ popq(RBX);       // Restore IC data.
  __ popq(RDX);       // Restore receiver.
  __ LeaveStubFrame();

  __ movq(RAX, FieldAddress(CODE_REG, target::Code::entry_point_offset()));
  __ jmp(RAX);  // Jump to original stub.
#endif  // defined(PRODUCT)
}

//  TOS(0): return address (Dart code).
void StubCodeCompiler::GenerateRuntimeCallBreakpointStub(Assembler* assembler) {
#if defined(PRODUCT)
  __ Stop("No debugging in PRODUCT mode");
#else
  __ EnterStubFrame();
  __ pushq(Immediate(0));  // Result slot.
  __ CallRuntime(kBreakpointRuntimeHandlerRuntimeEntry, 0);
  __ popq(CODE_REG);  // Original stub.
  __ LeaveStubFrame();

  __ movq(RAX, FieldAddress(CODE_REG, target::Code::entry_point_offset()));
  __ jmp(RAX);  // Jump to original stub.
#endif  // defined(PRODUCT)
}

// Called only from unoptimized code.
void StubCodeCompiler::GenerateDebugStepCheckStub(Assembler* assembler) {
#if defined(PRODUCT)
  __ Stop("No debugging in PRODUCT mode");
#else
  // Check single stepping.
  Label stepping, done_stepping;
  __ LoadIsolate(RAX);
  __ movzxb(RAX, Address(RAX, target::Isolate::single_step_offset()));
  __ cmpq(RAX, Immediate(0));
  __ j(NOT_EQUAL, &stepping, Assembler::kNearJump);
  __ Bind(&done_stepping);
  __ ret();

  __ Bind(&stepping);
  __ EnterStubFrame();
  __ CallRuntime(kSingleStepHandlerRuntimeEntry, 0);
  __ LeaveStubFrame();
  __ jmp(&done_stepping, Assembler::kNearJump);
#endif  // defined(PRODUCT)
}

// Used to check class and type arguments. Arguments passed in registers:
//
// Inputs:
//   - R9  : RawSubtypeTestCache
//   - RAX : instance to test against.
//   - RDX : instantiator type arguments (for n=4).
//   - RCX : function type arguments (for n=4).
//
//   - TOS + 0: return address.
//
// Preserves R9/RAX/RCX/RDX, RBX.
//
// Result in R8: null -> not found, otherwise result (true or false).
static void GenerateSubtypeNTestCacheStub(Assembler* assembler, int n) {
  ASSERT(n == 1 || n == 2 || n == 4 || n == 6);

  const Register kCacheReg = R9;
  const Register kInstanceReg = RAX;
  const Register kInstantiatorTypeArgumentsReg = RDX;
  const Register kFunctionTypeArgumentsReg = RCX;

  const Register kInstanceCidOrFunction = R10;
  const Register kInstanceInstantiatorTypeArgumentsReg = R13;
  const Register kInstanceParentFunctionTypeArgumentsReg = PP;
  const Register kInstanceDelayedFunctionTypeArgumentsReg = CODE_REG;

  const Register kNullReg = R8;

  __ LoadObject(kNullReg, NullObject());

  // Free up these 2 registers to be used for 6-value test.
  if (n >= 6) {
    __ pushq(kInstanceParentFunctionTypeArgumentsReg);
    __ pushq(kInstanceDelayedFunctionTypeArgumentsReg);
  }

  // Loop initialization (moved up here to avoid having all dependent loads
  // after each other).
  __ movq(RSI,
          FieldAddress(kCacheReg, target::SubtypeTestCache::cache_offset()));
  __ addq(RSI, Immediate(target::Array::data_offset() - kHeapObjectTag));

  Label loop, not_closure;
  if (n >= 4) {
    __ LoadClassIdMayBeSmi(kInstanceCidOrFunction, kInstanceReg);
  } else {
    __ LoadClassId(kInstanceCidOrFunction, kInstanceReg);
  }
  __ cmpq(kInstanceCidOrFunction, Immediate(kClosureCid));
  __ j(NOT_EQUAL, &not_closure, Assembler::kNearJump);

  // Closure handling.
  {
    __ movq(kInstanceCidOrFunction,
            FieldAddress(kInstanceReg, target::Closure::function_offset()));
    if (n >= 2) {
      __ movq(
          kInstanceInstantiatorTypeArgumentsReg,
          FieldAddress(kInstanceReg,
                       target::Closure::instantiator_type_arguments_offset()));
      if (n >= 6) {
        ASSERT(n == 6);
        __ movq(
            kInstanceParentFunctionTypeArgumentsReg,
            FieldAddress(kInstanceReg,
                         target::Closure::function_type_arguments_offset()));
        __ movq(kInstanceDelayedFunctionTypeArgumentsReg,
                FieldAddress(kInstanceReg,
                             target::Closure::delayed_type_arguments_offset()));
      }
    }
    __ jmp(&loop, Assembler::kNearJump);
  }

  // Non-Closure handling.
  {
    __ Bind(&not_closure);
    if (n == 1) {
      __ SmiTag(kInstanceCidOrFunction);
    } else {
      ASSERT(n >= 2);
      Label has_no_type_arguments;
      // [LoadClassById] also tags [kInstanceCidOrFunction] as a side-effect.
      __ LoadClassById(RDI, kInstanceCidOrFunction);
      __ movq(kInstanceInstantiatorTypeArgumentsReg, kNullReg);
      __ movl(
          RDI,
          FieldAddress(
              RDI,
              target::Class::type_arguments_field_offset_in_words_offset()));
      __ cmpl(RDI, Immediate(target::Class::kNoTypeArguments));
      __ j(EQUAL, &has_no_type_arguments, Assembler::kNearJump);
      __ movq(kInstanceInstantiatorTypeArgumentsReg,
              FieldAddress(kInstanceReg, RDI, TIMES_8, 0));
      __ Bind(&has_no_type_arguments);

      if (n >= 6) {
        __ movq(kInstanceParentFunctionTypeArgumentsReg, kNullReg);
        __ movq(kInstanceDelayedFunctionTypeArgumentsReg, kNullReg);
      }
    }
  }

  Label found, not_found, next_iteration;

  // Loop header.
  __ Bind(&loop);
  __ movq(
      RDI,
      Address(RSI, target::kWordSize *
                       target::SubtypeTestCache::kInstanceClassIdOrFunction));
  __ cmpq(RDI, kNullReg);
  __ j(EQUAL, &not_found, Assembler::kNearJump);
  __ cmpq(RDI, kInstanceCidOrFunction);
  if (n == 1) {
    __ j(EQUAL, &found, Assembler::kNearJump);
  } else {
    __ j(NOT_EQUAL, &next_iteration, Assembler::kNearJump);
    __ cmpq(kInstanceInstantiatorTypeArgumentsReg,
            Address(RSI, target::kWordSize *
                             target::SubtypeTestCache::kInstanceTypeArguments));
    if (n == 2) {
      __ j(EQUAL, &found, Assembler::kNearJump);
    } else {
      __ j(NOT_EQUAL, &next_iteration, Assembler::kNearJump);
      __ cmpq(
          kInstantiatorTypeArgumentsReg,
          Address(RSI,
                  target::kWordSize *
                      target::SubtypeTestCache::kInstantiatorTypeArguments));
      __ j(NOT_EQUAL, &next_iteration, Assembler::kNearJump);
      __ cmpq(
          kFunctionTypeArgumentsReg,
          Address(RSI, target::kWordSize *
                           target::SubtypeTestCache::kFunctionTypeArguments));

      if (n == 4) {
        __ j(EQUAL, &found, Assembler::kNearJump);
      } else {
        ASSERT(n == 6);
        __ j(NOT_EQUAL, &next_iteration, Assembler::kNearJump);

        __ cmpq(kInstanceParentFunctionTypeArgumentsReg,
                Address(RSI, target::kWordSize *
                                 target::SubtypeTestCache::
                                     kInstanceParentFunctionTypeArguments));
        __ j(NOT_EQUAL, &next_iteration, Assembler::kNearJump);
        __ cmpq(kInstanceDelayedFunctionTypeArgumentsReg,
                Address(RSI, target::kWordSize *
                                 target::SubtypeTestCache::
                                     kInstanceDelayedFunctionTypeArguments));
        __ j(EQUAL, &found, Assembler::kNearJump);
      }
    }
  }

  __ Bind(&next_iteration);
  __ addq(RSI, Immediate(target::kWordSize *
                         target::SubtypeTestCache::kTestEntryLength));
  __ jmp(&loop, Assembler::kNearJump);

  __ Bind(&found);
  __ movq(R8, Address(RSI, target::kWordSize *
                               target::SubtypeTestCache::kTestResult));
  if (n >= 6) {
    __ popq(kInstanceDelayedFunctionTypeArgumentsReg);
    __ popq(kInstanceParentFunctionTypeArgumentsReg);
  }
  __ ret();

  __ Bind(&not_found);
  if (n >= 6) {
    __ popq(kInstanceDelayedFunctionTypeArgumentsReg);
    __ popq(kInstanceParentFunctionTypeArgumentsReg);
  }
  __ ret();
}

// See comment on [GenerateSubtypeNTestCacheStub].
void StubCodeCompiler::GenerateSubtype1TestCacheStub(Assembler* assembler) {
  GenerateSubtypeNTestCacheStub(assembler, 1);
}

// See comment on [GenerateSubtypeNTestCacheStub].
void StubCodeCompiler::GenerateSubtype2TestCacheStub(Assembler* assembler) {
  GenerateSubtypeNTestCacheStub(assembler, 2);
}

// See comment on [GenerateSubtypeNTestCacheStub].
void StubCodeCompiler::GenerateSubtype4TestCacheStub(Assembler* assembler) {
  GenerateSubtypeNTestCacheStub(assembler, 4);
}

// See comment on [GenerateSubtypeNTestCacheStub].
void StubCodeCompiler::GenerateSubtype6TestCacheStub(Assembler* assembler) {
  GenerateSubtypeNTestCacheStub(assembler, 6);
}

// Used to test whether a given value is of a given type (different variants,
// all have the same calling convention).
//
// Inputs:
//   - R9  : RawSubtypeTestCache
//   - RAX : instance to test against.
//   - RDX : instantiator type arguments (if needed).
//   - RCX : function type arguments (if needed).
//
//   - RBX : type to test against.
//   - R10 : name of destination variable.
//
// Preserves R9/RAX/RCX/RDX, RBX, R10.
//
// Note of warning: The caller will not populate CODE_REG and we have therefore
// no access to the pool.
void StubCodeCompiler::GenerateDefaultTypeTestStub(Assembler* assembler) {
  Label done;

  const Register kInstanceReg = RAX;

  // Fast case for 'null'.
  __ CompareObject(kInstanceReg, NullObject());
  __ BranchIf(EQUAL, &done);

  __ movq(CODE_REG, Address(THR, target::Thread::slow_type_test_stub_offset()));
  __ jmp(FieldAddress(CODE_REG, target::Code::entry_point_offset()));

  __ Bind(&done);
  __ Ret();
}

void StubCodeCompiler::GenerateTopTypeTypeTestStub(Assembler* assembler) {
  __ Ret();
}

void StubCodeCompiler::GenerateTypeRefTypeTestStub(Assembler* assembler) {
  const Register kTypeRefReg = RBX;

  // We dereference the TypeRef and tail-call to it's type testing stub.
  __ movq(kTypeRefReg,
          FieldAddress(kTypeRefReg, target::TypeRef::type_offset()));
  __ jmp(FieldAddress(
      kTypeRefReg, target::AbstractType::type_test_stub_entry_point_offset()));
}

void StubCodeCompiler::GenerateUnreachableTypeTestStub(Assembler* assembler) {
  __ Breakpoint();
}

static void InvokeTypeCheckFromTypeTestStub(Assembler* assembler,
                                            TypeCheckMode mode) {
  const Register kInstanceReg = RAX;
  const Register kInstantiatorTypeArgumentsReg = RDX;
  const Register kFunctionTypeArgumentsReg = RCX;
  const Register kDstTypeReg = RBX;
  const Register kSubtypeTestCacheReg = R9;

  __ PushObject(NullObject());  // Make room for result.
  __ pushq(kInstanceReg);
  __ pushq(kDstTypeReg);
  __ pushq(kInstantiatorTypeArgumentsReg);
  __ pushq(kFunctionTypeArgumentsReg);
  __ PushObject(NullObject());
  __ pushq(kSubtypeTestCacheReg);
  __ PushImmediate(Immediate(target::ToRawSmi(mode)));
  __ CallRuntime(kTypeCheckRuntimeEntry, 7);
  __ Drop(1);
  __ popq(kSubtypeTestCacheReg);
  __ Drop(1);
  __ popq(kFunctionTypeArgumentsReg);
  __ popq(kInstantiatorTypeArgumentsReg);
  __ popq(kDstTypeReg);
  __ popq(kInstanceReg);
  __ Drop(1);  // Discard return value.
}

void StubCodeCompiler::GenerateLazySpecializeTypeTestStub(
    Assembler* assembler) {
  const Register kInstanceReg = RAX;

  Label done;

  // Fast case for 'null'.
  __ CompareObject(kInstanceReg, NullObject());
  __ BranchIf(EQUAL, &done);

  __ movq(
      CODE_REG,
      Address(THR, target::Thread::lazy_specialize_type_test_stub_offset()));
  __ EnterStubFrame();
  InvokeTypeCheckFromTypeTestStub(assembler, kTypeCheckFromLazySpecializeStub);
  __ LeaveStubFrame();

  __ Bind(&done);
  __ Ret();
}

void StubCodeCompiler::GenerateSlowTypeTestStub(Assembler* assembler) {
  Label done, call_runtime;

  const Register kInstanceReg = RAX;
  const Register kDstTypeReg = RBX;
  const Register kSubtypeTestCacheReg = R9;

  __ EnterStubFrame();

#ifdef DEBUG
  // Guaranteed by caller.
  Label no_error;
  __ CompareObject(kInstanceReg, NullObject());
  __ BranchIf(NOT_EQUAL, &no_error);
  __ Breakpoint();
  __ Bind(&no_error);
#endif

  // If the subtype-cache is null, it needs to be lazily-created by the runtime.
  __ CompareObject(kSubtypeTestCacheReg, NullObject());
  __ BranchIf(EQUAL, &call_runtime);

  const Register kTmp = RDI;

  // If this is not a [Type] object, we'll go to the runtime.
  Label is_simple_case, is_complex_case;
  __ LoadClassId(kTmp, kDstTypeReg);
  __ cmpq(kTmp, Immediate(kTypeCid));
  __ BranchIf(NOT_EQUAL, &is_complex_case);

  // Check whether this [Type] is instantiated/uninstantiated.
  __ cmpb(FieldAddress(kDstTypeReg, target::Type::type_state_offset()),
          Immediate(target::RawAbstractType::kTypeStateFinalizedInstantiated));
  __ BranchIf(NOT_EQUAL, &is_complex_case);

  // Check whether this [Type] is a function type.
  __ movq(kTmp, FieldAddress(kDstTypeReg, target::Type::signature_offset()));
  __ CompareObject(kTmp, NullObject());
  __ BranchIf(NOT_EQUAL, &is_complex_case);

  // This [Type] could be a FutureOr. Subtype2TestCache does not support Smi.
  __ BranchIfSmi(kInstanceReg, &is_complex_case);

  // Fall through to &is_simple_case

  __ Bind(&is_simple_case);
  {
    __ Call(StubCodeSubtype2TestCache());
    __ CompareObject(R8, CastHandle<Object>(TrueObject()));
    __ BranchIf(EQUAL, &done);  // Cache said: yes.
    __ Jump(&call_runtime);
  }

  __ Bind(&is_complex_case);
  {
    __ Call(StubCodeSubtype6TestCache());
    __ CompareObject(R8, CastHandle<Object>(TrueObject()));
    __ BranchIf(EQUAL, &done);  // Cache said: yes.
    // Fall through to runtime_call
  }

  __ Bind(&call_runtime);

  // We cannot really ensure here that dynamic/Object/void never occur here
  // (though it is guaranteed at dart_precompiled_runtime time).  This is
  // because we do constant evaluation with default stubs and only install
  // optimized versions before writing out the AOT snapshot.
  // So dynamic/Object/void will run with default stub in constant evaluation.
  __ CompareObject(kDstTypeReg, CastHandle<Object>(DynamicType()));
  __ BranchIf(EQUAL, &done);
  __ CompareObject(kDstTypeReg, CastHandle<Object>(ObjectType()));
  __ BranchIf(EQUAL, &done);
  __ CompareObject(kDstTypeReg, CastHandle<Object>(VoidType()));
  __ BranchIf(EQUAL, &done);

  InvokeTypeCheckFromTypeTestStub(assembler, kTypeCheckFromSlowStub);

  __ Bind(&done);
  __ LeaveStubFrame();
  __ Ret();
}

// Return the current stack pointer address, used to stack alignment
// checks.
// TOS + 0: return address
// Result in RAX.
void StubCodeCompiler::GenerateGetCStackPointerStub(Assembler* assembler) {
  __ leaq(RAX, Address(RSP, target::kWordSize));
  __ ret();
}

// Jump to a frame on the call stack.
// TOS + 0: return address
// Arg1: program counter
// Arg2: stack pointer
// Arg3: frame_pointer
// Arg4: thread
// No Result.
void StubCodeCompiler::GenerateJumpToFrameStub(Assembler* assembler) {
  __ movq(THR, CallingConventions::kArg4Reg);
  __ movq(RBP, CallingConventions::kArg3Reg);
  __ movq(RSP, CallingConventions::kArg2Reg);
  // Set the tag.
  __ movq(Assembler::VMTagAddress(), Immediate(VMTag::kDartCompiledTagId));
  // Clear top exit frame.
  __ movq(Address(THR, target::Thread::top_exit_frame_info_offset()),
          Immediate(0));
  // Restore the pool pointer.
  __ RestoreCodePointer();
  if (FLAG_precompiled_mode && FLAG_use_bare_instructions) {
    __ movq(PP, Address(THR, target::Thread::global_object_pool_offset()));
  } else {
    __ LoadPoolPointer(PP);
  }
  __ jmp(CallingConventions::kArg1Reg);  // Jump to program counter.
}

// Run an exception handler.  Execution comes from JumpToFrame stub.
//
// The arguments are stored in the Thread object.
// No result.
void StubCodeCompiler::GenerateRunExceptionHandlerStub(Assembler* assembler) {
  ASSERT(kExceptionObjectReg == RAX);
  ASSERT(kStackTraceObjectReg == RDX);
  __ movq(CallingConventions::kArg1Reg,
          Address(THR, target::Thread::resume_pc_offset()));

  word offset_from_thread = 0;
  bool ok = target::CanLoadFromThread(NullObject(), &offset_from_thread);
  ASSERT(ok);
  __ movq(TMP, Address(THR, offset_from_thread));

  // Load the exception from the current thread.
  Address exception_addr(THR, target::Thread::active_exception_offset());
  __ movq(kExceptionObjectReg, exception_addr);
  __ movq(exception_addr, TMP);

  // Load the stacktrace from the current thread.
  Address stacktrace_addr(THR, target::Thread::active_stacktrace_offset());
  __ movq(kStackTraceObjectReg, stacktrace_addr);
  __ movq(stacktrace_addr, TMP);

  __ jmp(CallingConventions::kArg1Reg);  // Jump to continuation point.
}

// Deoptimize a frame on the call stack before rewinding.
// The arguments are stored in the Thread object.
// No result.
void StubCodeCompiler::GenerateDeoptForRewindStub(Assembler* assembler) {
  // Push zap value instead of CODE_REG.
  __ pushq(Immediate(kZapCodeReg));

  // Push the deopt pc.
  __ pushq(Address(THR, target::Thread::resume_pc_offset()));
  GenerateDeoptimizationSequence(assembler, kEagerDeopt);

  // After we have deoptimized, jump to the correct frame.
  __ EnterStubFrame();
  __ CallRuntime(kRewindPostDeoptRuntimeEntry, 0);
  __ LeaveStubFrame();
  __ int3();
}

// Calls to the runtime to optimize the given function.
// RDI: function to be reoptimized.
// R10: argument descriptor (preserved).
void StubCodeCompiler::GenerateOptimizeFunctionStub(Assembler* assembler) {
  __ movq(CODE_REG, Address(THR, target::Thread::optimize_stub_offset()));
  __ EnterStubFrame();
  __ pushq(R10);           // Preserve args descriptor.
  __ pushq(Immediate(0));  // Result slot.
  __ pushq(RDI);           // Arg0: function to optimize
  __ CallRuntime(kOptimizeInvokedFunctionRuntimeEntry, 1);
  __ popq(RAX);  // Discard argument.
  __ popq(RAX);  // Get Code object.
  __ popq(R10);  // Restore argument descriptor.
  __ LeaveStubFrame();
  __ movq(CODE_REG, FieldAddress(RAX, target::Function::code_offset()));
  __ movq(RCX, FieldAddress(RAX, target::Function::entry_point_offset()));
  __ jmp(RCX);
  __ int3();
}

// Does identical check (object references are equal or not equal) with special
// checks for boxed numbers.
// Left and right are pushed on stack.
// Return ZF set.
// Note: A Mint cannot contain a value that would fit in Smi.
static void GenerateIdenticalWithNumberCheckStub(Assembler* assembler,
                                                 const Register left,
                                                 const Register right) {
  Label reference_compare, done, check_mint;
  // If any of the arguments is Smi do reference compare.
  __ testq(left, Immediate(kSmiTagMask));
  __ j(ZERO, &reference_compare);
  __ testq(right, Immediate(kSmiTagMask));
  __ j(ZERO, &reference_compare);

  // Value compare for two doubles.
  __ CompareClassId(left, kDoubleCid);
  __ j(NOT_EQUAL, &check_mint, Assembler::kNearJump);
  __ CompareClassId(right, kDoubleCid);
  __ j(NOT_EQUAL, &done, Assembler::kFarJump);

  // Double values bitwise compare.
  __ movq(left, FieldAddress(left, target::Double::value_offset()));
  __ cmpq(left, FieldAddress(right, target::Double::value_offset()));
  __ jmp(&done, Assembler::kFarJump);

  __ Bind(&check_mint);
  __ CompareClassId(left, kMintCid);
  __ j(NOT_EQUAL, &reference_compare, Assembler::kNearJump);
  __ CompareClassId(right, kMintCid);
  __ j(NOT_EQUAL, &done, Assembler::kFarJump);
  __ movq(left, FieldAddress(left, target::Mint::value_offset()));
  __ cmpq(left, FieldAddress(right, target::Mint::value_offset()));
  __ jmp(&done, Assembler::kFarJump);

  __ Bind(&reference_compare);
  __ cmpq(left, right);
  __ Bind(&done);
}

// Called only from unoptimized code. All relevant registers have been saved.
// TOS + 0: return address
// TOS + 1: right argument.
// TOS + 2: left argument.
// Returns ZF set.
void StubCodeCompiler::GenerateUnoptimizedIdenticalWithNumberCheckStub(
    Assembler* assembler) {
#if !defined(PRODUCT)
  // Check single stepping.
  Label stepping, done_stepping;
  __ LoadIsolate(RAX);
  __ movzxb(RAX, Address(RAX, target::Isolate::single_step_offset()));
  __ cmpq(RAX, Immediate(0));
  __ j(NOT_EQUAL, &stepping);
  __ Bind(&done_stepping);
#endif

  const Register left = RAX;
  const Register right = RDX;

  __ movq(left, Address(RSP, 2 * target::kWordSize));
  __ movq(right, Address(RSP, 1 * target::kWordSize));
  GenerateIdenticalWithNumberCheckStub(assembler, left, right);
  __ ret();

#if !defined(PRODUCT)
  __ Bind(&stepping);
  __ EnterStubFrame();
  __ CallRuntime(kSingleStepHandlerRuntimeEntry, 0);
  __ RestoreCodePointer();
  __ LeaveStubFrame();
  __ jmp(&done_stepping);
#endif
}

// Called from optimized code only.
// TOS + 0: return address
// TOS + 1: right argument.
// TOS + 2: left argument.
// Returns ZF set.
void StubCodeCompiler::GenerateOptimizedIdenticalWithNumberCheckStub(
    Assembler* assembler) {
  const Register left = RAX;
  const Register right = RDX;

  __ movq(left, Address(RSP, 2 * target::kWordSize));
  __ movq(right, Address(RSP, 1 * target::kWordSize));
  GenerateIdenticalWithNumberCheckStub(assembler, left, right);
  __ ret();
}

// Called from megamorphic calls.
//  RDX: receiver
//  RBX: target::MegamorphicCache (preserved)
// Passed to target:
//  CODE_REG: target Code
//  R10: arguments descriptor
void StubCodeCompiler::GenerateMegamorphicCallStub(Assembler* assembler) {
  // Jump if receiver is a smi.
  Label smi_case;
  __ testq(RDX, Immediate(kSmiTagMask));
  // Jump out of line for smi case.
  __ j(ZERO, &smi_case, Assembler::kNearJump);

  // Loads the cid of the object.
  __ LoadClassId(RAX, RDX);

  Label cid_loaded;
  __ Bind(&cid_loaded);
  __ movq(R9, FieldAddress(RBX, target::MegamorphicCache::mask_offset()));
  __ movq(RDI, FieldAddress(RBX, target::MegamorphicCache::buckets_offset()));
  // R9: mask as a smi.
  // RDI: cache buckets array.

  // Tag cid as a smi.
  __ addq(RAX, RAX);

  // Compute the table index.
  ASSERT(target::MegamorphicCache::kSpreadFactor == 7);
  // Use leaq and subq multiply with 7 == 8 - 1.
  __ leaq(RCX, Address(RAX, TIMES_8, 0));
  __ subq(RCX, RAX);

  Label loop;
  __ Bind(&loop);
  __ andq(RCX, R9);

  const intptr_t base = target::Array::data_offset();
  // RCX is smi tagged, but table entries are two words, so TIMES_8.
  Label probe_failed;
  __ cmpq(RAX, FieldAddress(RDI, RCX, TIMES_8, base));
  __ j(NOT_EQUAL, &probe_failed, Assembler::kNearJump);

  Label load_target;
  __ Bind(&load_target);
  // Call the target found in the cache.  For a class id match, this is a
  // proper target for the given name and arguments descriptor.  If the
  // illegal class id was found, the target is a cache miss handler that can
  // be invoked as a normal Dart function.
  const auto target_address =
      FieldAddress(RDI, RCX, TIMES_8, base + target::kWordSize);
  if (FLAG_precompiled_mode && FLAG_use_bare_instructions) {
    __ movq(R10,
            FieldAddress(
                RBX, target::MegamorphicCache::arguments_descriptor_offset()));
    __ jmp(target_address);
  } else {
    __ movq(RAX, target_address);
    __ movq(R10,
            FieldAddress(
                RBX, target::MegamorphicCache::arguments_descriptor_offset()));
    __ movq(RCX, FieldAddress(RAX, target::Function::entry_point_offset()));
    __ movq(CODE_REG, FieldAddress(RAX, target::Function::code_offset()));
    __ jmp(RCX);
  }

  // Probe failed, check if it is a miss.
  __ Bind(&probe_failed);
  __ cmpq(FieldAddress(RDI, RCX, TIMES_8, base),
          Immediate(target::ToRawSmi(kIllegalCid)));
  __ j(ZERO, &load_target, Assembler::kNearJump);

  // Try next entry in the table.
  __ AddImmediate(RCX, Immediate(target::ToRawSmi(1)));
  __ jmp(&loop);

  // Load cid for the Smi case.
  __ Bind(&smi_case);
  __ movq(RAX, Immediate(kSmiCid));
  __ jmp(&cid_loaded);
}

void StubCodeCompiler::GenerateICCallThroughCodeStub(Assembler* assembler) {
  Label loop, found, miss;
  __ movq(R13, FieldAddress(RBX, target::ICData::entries_offset()));
  __ movq(R10,
          FieldAddress(RBX, target::ICData::arguments_descriptor_offset()));
  __ leaq(R13, FieldAddress(R13, target::Array::data_offset()));
  // R13: first IC entry
  __ LoadTaggedClassIdMayBeSmi(RAX, RDX);
  // RAX: receiver cid as Smi

  __ Bind(&loop);
  __ movq(R9, Address(R13, 0));
  __ cmpq(RAX, R9);
  __ j(EQUAL, &found, Assembler::kNearJump);

  ASSERT(target::ToRawSmi(kIllegalCid) == 0);
  __ testq(R9, R9);
  __ j(ZERO, &miss, Assembler::kNearJump);

  const intptr_t entry_length =
      target::ICData::TestEntryLengthFor(1, /*tracking_exactness=*/false) *
      target::kWordSize;
  __ addq(R13, Immediate(entry_length));  // Next entry.
  __ jmp(&loop);

  __ Bind(&found);
  const intptr_t code_offset =
      target::ICData::CodeIndexFor(1) * target::kWordSize;
  const intptr_t entry_offset =
      target::ICData::EntryPointIndexFor(1) * target::kWordSize;
  if (!(FLAG_precompiled_mode && FLAG_use_bare_instructions)) {
    __ movq(CODE_REG, Address(R13, code_offset));
  }
  __ jmp(Address(R13, entry_offset));

  __ Bind(&miss);
  __ LoadIsolate(RAX);
  __ movq(CODE_REG, Address(RAX, target::Isolate::ic_miss_code_offset()));
  __ movq(RCX, FieldAddress(CODE_REG, target::Code::entry_point_offset()));
  __ jmp(RCX);
}

//  RDX: receiver
//  RBX: UnlinkedCall
void StubCodeCompiler::GenerateUnlinkedCallStub(Assembler* assembler) {
  __ EnterStubFrame();
  __ pushq(RDX);  // Preserve receiver.

  __ pushq(Immediate(0));  // Result slot.
  __ pushq(Immediate(0));  // Arg0: stub out.
  __ pushq(RDX);           // Arg1: Receiver
  __ pushq(RBX);           // Arg2: UnlinkedCall
  __ CallRuntime(kUnlinkedCallRuntimeEntry, 3);
  __ popq(RBX);
  __ popq(RBX);
  __ popq(CODE_REG);  // result = stub
  __ popq(RBX);       // result = IC

  __ popq(RDX);  // Restore receiver.
  __ LeaveStubFrame();

  __ movq(RCX, FieldAddress(CODE_REG, target::Code::entry_point_offset(
                                          CodeEntryKind::kMonomorphic)));
  __ jmp(RCX);
}

// Called from switchable IC calls.
//  RDX: receiver
//  RBX: SingleTargetCache
// Passed to target::
//  CODE_REG: target Code object
void StubCodeCompiler::GenerateSingleTargetCallStub(Assembler* assembler) {
  Label miss;
  __ LoadClassIdMayBeSmi(RAX, RDX);
  __ movzxw(R9,
            FieldAddress(RBX, target::SingleTargetCache::lower_limit_offset()));
  __ movzxw(R10,
            FieldAddress(RBX, target::SingleTargetCache::upper_limit_offset()));
  __ cmpq(RAX, R9);
  __ j(LESS, &miss, Assembler::kNearJump);
  __ cmpq(RAX, R10);
  __ j(GREATER, &miss, Assembler::kNearJump);
  __ movq(RCX,
          FieldAddress(RBX, target::SingleTargetCache::entry_point_offset()));
  __ movq(CODE_REG,
          FieldAddress(RBX, target::SingleTargetCache::target_offset()));
  __ jmp(RCX);

  __ Bind(&miss);
  __ EnterStubFrame();
  __ pushq(RDX);  // Preserve receiver.

  __ pushq(Immediate(0));  // Result slot.
  __ pushq(Immediate(0));  // Arg0: stub out
  __ pushq(RDX);           // Arg1: Receiver
  __ CallRuntime(kSingleTargetMissRuntimeEntry, 2);
  __ popq(RBX);
  __ popq(CODE_REG);  // result = stub
  __ popq(RBX);       // result = IC

  __ popq(RDX);  // Restore receiver.
  __ LeaveStubFrame();

  __ movq(RCX, FieldAddress(CODE_REG, target::Code::entry_point_offset(
                                          CodeEntryKind::kMonomorphic)));
  __ jmp(RCX);
}

// Called from the monomorphic checked entry.
//  RDX: receiver
void StubCodeCompiler::GenerateMonomorphicMissStub(Assembler* assembler) {
  __ movq(CODE_REG,
          Address(THR, target::Thread::monomorphic_miss_stub_offset()));
  __ EnterStubFrame();
  __ pushq(RDX);  // Preserve receiver.

  __ pushq(Immediate(0));  // Result slot.
  __ pushq(Immediate(0));  // Arg0: stub out.
  __ pushq(RDX);           // Arg1: Receiver
  __ CallRuntime(kMonomorphicMissRuntimeEntry, 2);
  __ popq(RBX);
  __ popq(CODE_REG);  // result = stub
  __ popq(RBX);       // result = IC

  __ popq(RDX);  // Restore receiver.
  __ LeaveStubFrame();

  __ movq(RCX, FieldAddress(CODE_REG, target::Code::entry_point_offset(
                                          CodeEntryKind::kMonomorphic)));
  __ jmp(RCX);
}

void StubCodeCompiler::GenerateFrameAwaitingMaterializationStub(
    Assembler* assembler) {
  __ int3();
}

void StubCodeCompiler::GenerateAsynchronousGapMarkerStub(Assembler* assembler) {
  __ int3();
}

}  // namespace compiler

}  // namespace dart

#endif  // defined(TARGET_ARCH_X64) && !defined(DART_PRECOMPILED_RUNTIME)
