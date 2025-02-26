// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_COMPILER_RUNTIME_API_H_
#define RUNTIME_VM_COMPILER_RUNTIME_API_H_

// This header defines the API that compiler can use to interact with the
// underlying Dart runtime that it is embedded into.
//
// Compiler is not allowed to directly interact with any objects - it can only
// use classes like dart::Object, dart::Code, dart::Function and similar as
// opaque handles. All interactions should be done through helper methods
// provided by this header.
//
// This header also provides ways to get word sizes, frame layout, field
// offsets for the target runtime. Note that these can be different from
// those on the host. Helpers providing access to these values live
// in compiler::target namespace.

#include "platform/globals.h"
#include "vm/allocation.h"
#include "vm/bitfield.h"
#include "vm/class_id.h"
#include "vm/code_entry_kind.h"
#include "vm/constants.h"
#include "vm/frame_layout.h"
#include "vm/pointer_tagging.h"
#include "vm/runtime_entry_list.h"
#include "vm/token.h"

namespace dart {

// Forward declarations.
class LocalVariable;
class Object;
class RuntimeEntry;
class Zone;

#define DO(clazz)                                                              \
  class Raw##clazz;                                                            \
  class clazz;
CLASS_LIST_FOR_HANDLES(DO)
#undef DO

namespace compiler {
class Assembler;
}

namespace compiler {

// Host word sizes.
//
// Code in the compiler namespace should not use kWordSize and derived
// constants directly because the word size on host and target might
// be different.
//
// To prevent this we introduce variables that would shadow these
// constants and introduce compilation errors when used.
//
// target::kWordSize and target::ObjectAlignment give access to
// word size and object aligment offsets for the target.
//
// Similarly kHostWordSize gives access to the host word size.
class InvalidClass {};
extern InvalidClass kWordSize;
extern InvalidClass kWordSizeLog2;
extern InvalidClass kBitsPerWord;
extern InvalidClass kNewObjectAlignmentOffset;
extern InvalidClass kOldObjectAlignmentOffset;
extern InvalidClass kNewObjectBitPosition;
extern InvalidClass kObjectAlignment;
extern InvalidClass kObjectAlignmentLog2;
extern InvalidClass kObjectAlignmentMask;
extern InvalidClass kSmiBits;
extern InvalidClass kSmiMin;
extern InvalidClass kSmiMax;

static constexpr intptr_t kHostWordSize = dart::kWordSize;
static constexpr intptr_t kHostWordSizeLog2 = dart::kWordSizeLog2;

//
// Object handles.
//

// Create an empty handle.
Object& NewZoneHandle(Zone* zone);

// Clone the given handle.
Object& NewZoneHandle(Zone* zone, const Object&);

//
// Constant objects.
//

const Object& NullObject();
const Bool& TrueObject();
const Bool& FalseObject();
const Object& EmptyTypeArguments();
const Type& DynamicType();
const Type& ObjectType();
const Type& VoidType();
const Type& IntType();
const Class& GrowableObjectArrayClass();
const Class& MintClass();
const Class& DoubleClass();

template <typename To, typename From>
const To& CastHandle(const From& from) {
  return reinterpret_cast<const To&>(from);
}

// Returns true if [a] and [b] are the same object.
bool IsSameObject(const Object& a, const Object& b);

// Returns true if [a] and [b] represent the same type (are equal).
bool IsEqualType(const AbstractType& a, const AbstractType& b);

// Returns true if [type] is the "int" type.
bool IsIntType(const AbstractType& type);

// Returns true if [type] is the "double" type.
bool IsDoubleType(const AbstractType& type);

// Returns true if [type] is the "_Smi" type.
bool IsSmiType(const AbstractType& type);

// Returns true if the given handle is a zone handle or one of the global
// cached handles.
bool IsNotTemporaryScopedHandle(const Object& obj);

// Returns true if [obj] resides in old space.
bool IsInOldSpace(const Object& obj);

// Returns true if [obj] is not a Field/ICData clone.
//
// Used to assert that we are not embedding pointers to cloned objects that are
// used by background compiler into object pools / code.
bool IsOriginalObject(const Object& object);

// Clear the given handle.
void SetToNull(Object* obj);

// Helper functions to upcast handles.
//
// Note: compiler code cannot include object.h so it cannot see that Object is
// a superclass of Code or Function - thus we have to cast these pointers using
// reinterpret_cast.
inline const Object& ToObject(const Code& handle) {
  return *reinterpret_cast<const Object*>(&handle);
}

inline const Object& ToObject(const Function& handle) {
  return *reinterpret_cast<const Object*>(&handle);
}

// Returns some hash value for the given object.
//
// Note: the given hash value does not necessarily match Object.get:hashCode,
// or canonical hash.
intptr_t ObjectHash(const Object& obj);

// If the given object represents a Dart integer returns true and sets [value]
// to the value of the integer.
bool HasIntegerValue(const dart::Object& obj, int64_t* value);

// Creates a random cookie to be used for masking constants embedded in the
// generated code.
int32_t CreateJitCookie();

// Returns the size in bytes for the given class id.
word TypedDataElementSizeInBytes(classid_t cid);

// Returns the size in bytes for the given class id.
word TypedDataMaxNewSpaceElements(classid_t cid);

// Looks up the dart:math's _Random._A field.
const Field& LookupMathRandomStateFieldOffset();

// Returns the offset in bytes of [field].
word LookupFieldOffsetInBytes(const Field& field);

#if defined(TARGET_ARCH_IA32)
uword SymbolsPredefinedAddress();
#endif

typedef void (*RuntimeEntryCallInternal)(const dart::RuntimeEntry*,
                                         Assembler*,
                                         intptr_t);

#if !defined(TARGET_ARCH_DBC)
const Code& StubCodeAllocateArray();
const Code& StubCodeSubtype2TestCache();
const Code& StubCodeSubtype6TestCache();
#endif  // !defined(TARGET_ARCH_DBC)

class RuntimeEntry : public ValueObject {
 public:
  virtual ~RuntimeEntry() {}

  void Call(Assembler* assembler, intptr_t argument_count) const {
    ASSERT(call_ != NULL);
    ASSERT(runtime_entry_ != NULL);

    // We call a manually set function pointer which points to the
    // implementation of call for the subclass. We do this instead of just
    // defining Call in this class as a pure virtual method and providing an
    // implementation in the subclass as RuntimeEntry objects are declared as
    // globals which causes problems on Windows.
    //
    // When exit() is called on Windows, global objects start to be destroyed.
    // As part of an object's destruction, the vtable is reset to that of the
    // base class. Since some threads may still be running and accessing these
    // now destroyed globals, an invocation to dart::RuntimeEntry::Call would
    // instead invoke dart::compiler::RuntimeEntry::Call. If
    // dart::compiler::RuntimeEntry::Call were a pure virtual method, _purecall
    // would be invoked to handle the invalid call and attempt to call exit(),
    // causing the process to hang on a lock.
    //
    // By removing the need to rely on a potentially invalid vtable at exit,
    // we should be able to avoid hanging or crashing the process at shutdown,
    // even as global objects start to be destroyed. See issue #35855.
    call_(runtime_entry_, assembler, argument_count);
  }

  word OffsetFromThread() const;

 protected:
  RuntimeEntry(const dart::RuntimeEntry* runtime_entry,
               RuntimeEntryCallInternal call)
      : runtime_entry_(runtime_entry), call_(call) {}

 private:
  const dart::RuntimeEntry* runtime_entry_;
  RuntimeEntryCallInternal call_;
};

#define DECLARE_RUNTIME_ENTRY(name)                                            \
  extern const RuntimeEntry& k##name##RuntimeEntry;
RUNTIME_ENTRY_LIST(DECLARE_RUNTIME_ENTRY)
#undef DECLARE_RUNTIME_ENTRY

#define DECLARE_RUNTIME_ENTRY(type, name, ...)                                 \
  extern const RuntimeEntry& k##name##RuntimeEntry;
LEAF_RUNTIME_ENTRY_LIST(DECLARE_RUNTIME_ENTRY)
#undef DECLARE_RUNTIME_ENTRY

// Allocate a string object with the given content in the runtime heap.
const String& AllocateString(const char* buffer);

DART_NORETURN void BailoutWithBranchOffsetError();

// compiler::target namespace contains information about the target platform:
//
//    - word sizes and derived constants
//    - offsets of fields
//    - sizes of structures
namespace target {

#if defined(TARGET_ARCH_IS_32_BIT)
typedef int32_t word;
typedef uint32_t uword;
static constexpr word kWordSize = 4;
static constexpr word kWordSizeLog2 = 2;
#elif defined(TARGET_ARCH_IS_64_BIT)
typedef int64_t word;
typedef uint64_t uword;
static constexpr word kWordSize = 8;
static constexpr word kWordSizeLog2 = 3;
#else
#error "Unsupported architecture"
#endif

static constexpr word kBitsPerWord = 8 * kWordSize;
static_assert((1 << kWordSizeLog2) == kWordSize,
              "kWordSizeLog2 should match kWordSize");

using ObjectAlignment = dart::ObjectAlignment<kWordSize, kWordSizeLog2>;

const intptr_t kSmiBits = kBitsPerWord - 2;
const intptr_t kSmiMax = (static_cast<intptr_t>(1) << kSmiBits) - 1;
const intptr_t kSmiMin = -(static_cast<intptr_t>(1) << kSmiBits);

// Information about heap pages.
extern const word kPageSize;
extern const word kPageSizeInWords;
extern const word kPageMask;

// Information about frame_layout that compiler should be targeting.
extern FrameLayout frame_layout;

// Returns the FP-relative index where [variable] can be found (assumes
// [variable] is not captured), in bytes.
inline int FrameOffsetInBytesForVariable(const LocalVariable* variable) {
  return frame_layout.FrameSlotForVariable(variable) * kWordSize;
}

// Encode tag word for a heap allocated object with the given class id and
// size.
//
// Note: even on 64-bit platforms we only use lower 32-bits of the tag word.
uint32_t MakeTagWordForNewSpaceObject(classid_t cid, uword instance_size);

//
// Target specific information about objects.
//

// Returns true if the given object can be represented as a Smi on the target
// platform.
bool IsSmi(const dart::Object& a);

// Returns true if the given value can be represented as a Smi on the target
// platform.
bool IsSmi(int64_t value);

// Return raw Smi representation of the given object for the target platform.
word ToRawSmi(const dart::Object& a);

// Return raw Smi representation of the given integer value for the target
// platform.
//
// Note: method assumes that caller has validated that value is representable
// as a Smi.
word ToRawSmi(intptr_t value);

word SmiValue(const dart::Object& a);

// If the given object can be loaded from the thread on the target then
// return true and set offset (if provided) to the offset from the
// thread pointer to a field that contains the object.
bool CanLoadFromThread(const dart::Object& object, intptr_t* offset = nullptr);

// On IA32 we can embed raw pointers into generated code.
#if defined(TARGET_ARCH_IA32)
// Returns true if the pointer to the given object can be directly embedded
// into the generated code (because the object is immortal and immovable).
bool CanEmbedAsRawPointerInGeneratedCode(const dart::Object& obj);

// Returns raw pointer value for the given object. Should only be invoked
// if CanEmbedAsRawPointerInGeneratedCode returns true.
word ToRawPointer(const dart::Object& a);
#endif  // defined(TARGET_ARCH_IA32)

//
// Target specific offsets and constants.
//
// Currently we use the same names for classes, constants and getters to make
// migration easier.

class RawObject : public AllStatic {
 public:
  static const word kCardRememberedBit;
  static const word kOldAndNotRememberedBit;
  static const word kOldAndNotMarkedBit;
  static const word kClassIdTagPos;
  static const word kClassIdTagSize;
  static const word kSizeTagMaxSizeTag;
  static const word kTagBitsSizeTagPos;
  static const word kBarrierOverlapShift;

  static bool IsTypedDataClassId(intptr_t cid);
};

class RawAbstractType : public AllStatic {
 public:
  static const word kTypeStateFinalizedInstantiated;
};

class Object : public AllStatic {
 public:
  // Offset of the tags word.
  static word tags_offset();
  static word InstanceSize();
};

class ObjectPool : public AllStatic {
 public:
  // Return offset to the element with the given [index] in the object pool.
  static word element_offset(intptr_t index);
};

class Class : public AllStatic {
 public:
  static word type_arguments_field_offset_in_words_offset();

  static word declaration_type_offset();

  static word super_type_offset();

  // The offset of the RawObject::num_type_arguments_ field in bytes.
  static word num_type_arguments_offset();

  // The value used if no type arguments vector is present.
  static const word kNoTypeArguments;

  // Return class id of the given class on the target.
  static classid_t GetId(const dart::Class& handle);

  // Return instance size for the given class on the target.
  static uword GetInstanceSize(const dart::Class& handle);

  // Returns the number of type arguments.
  static intptr_t NumTypeArguments(const dart::Class& klass);

  // Whether [klass] has a type arguments vector field.
  static bool HasTypeArgumentsField(const dart::Class& klass);

  // Returns the offset (in bytes) of the type arguments vector.
  static intptr_t TypeArgumentsFieldOffset(const dart::Class& klass);

  // Whether to trace allocation for this klass.
  static bool TraceAllocation(const dart::Class& klass);
};

class Instance : public AllStatic {
 public:
  // Returns the offset to the first field of [RawInstance].
  static word first_field_offset();
  static word DataOffsetFor(intptr_t cid);
  static word ElementSizeFor(intptr_t cid);
  static word InstanceSize();
};

class Function : public AllStatic {
 public:
  static word code_offset();
  static word entry_point_offset();
  static word usage_counter_offset();
  static word unchecked_entry_point_offset();
};

class ICData : public AllStatic {
 public:
  static word owner_offset();
  static word arguments_descriptor_offset();
  static word entries_offset();
  static word receivers_static_type_offset();
  static word state_bits_offset();

  static word CodeIndexFor(word num_args);
  static word CountIndexFor(word num_args);
  static word TargetIndexFor(word num_args);
  static word ExactnessIndexFor(word num_args);
  static word TestEntryLengthFor(word num_args, bool exactness_check);
  static word EntryPointIndexFor(word num_args);
  static word NumArgsTestedShift();
  static word NumArgsTestedMask();
};

class MegamorphicCache : public AllStatic {
 public:
  static const word kSpreadFactor;
  static word mask_offset();
  static word buckets_offset();
  static word arguments_descriptor_offset();
};

class SingleTargetCache : public AllStatic {
 public:
  static word lower_limit_offset();
  static word upper_limit_offset();
  static word entry_point_offset();
  static word target_offset();
};

class Array : public AllStatic {
 public:
  static word header_size();
  static word tags_offset();
  static word data_offset();
  static word type_arguments_offset();
  static word length_offset();
  static word element_offset(intptr_t index);

  static const word kMaxElements;
  static const word kMaxNewSpaceElements;
};

class GrowableObjectArray : public AllStatic {
 public:
  static word data_offset();
  static word type_arguments_offset();
  static word length_offset();
  static word InstanceSize();
};

class TypedDataBase : public AllStatic {
 public:
  static word data_field_offset();
  static word length_offset();
  static word InstanceSize();
};

class TypedData : public AllStatic {
 public:
  static word data_offset();
  static word InstanceSize();
};

class ExternalTypedData : public AllStatic {
 public:
  static word data_offset();
};

class TypedDataView : public AllStatic {
 public:
  static word offset_in_bytes_offset();
  static word data_offset();
};

class LinkedHashMap : public AllStatic {
 public:
  static word index_offset();
  static word data_offset();
  static word hash_mask_offset();
  static word used_data_offset();
  static word deleted_keys_offset();
  static word InstanceSize();
};

class ArgumentsDescriptor : public AllStatic {
 public:
  static word first_named_entry_offset();
  static word named_entry_size();
  static word position_offset();
  static word name_offset();
  static word count_offset();
  static word type_args_len_offset();
  static word positional_count_offset();
};

class Pointer : public AllStatic {
 public:
  static word c_memory_address_offset();
};

class AbstractType : public AllStatic {
 public:
  static word type_test_stub_entry_point_offset();
};

class Type : public AllStatic {
 public:
  static word hash_offset();
  static word type_state_offset();
  static word arguments_offset();
  static word signature_offset();
  static word type_class_id_offset();
};

class TypeRef : public AllStatic {
 public:
  static word type_offset();
};

class Double : public AllStatic {
 public:
  static word value_offset();
  static word InstanceSize();
};

class Mint : public AllStatic {
 public:
  static word value_offset();
  static word InstanceSize();
};

class String : public AllStatic {
 public:
  static const word kHashBits;
  static const word kMaxElements;
  static word hash_offset();
  static word length_offset();
  static word InstanceSize();
};

class OneByteString : public AllStatic {
 public:
  static word data_offset();
};

class TwoByteString : public AllStatic {
 public:
  static word data_offset();
};

class ExternalOneByteString : public AllStatic {
 public:
  static word external_data_offset();
};

class ExternalTwoByteString : public AllStatic {
 public:
  static word external_data_offset();
};

class Int32x4 : public AllStatic {
 public:
  static word InstanceSize();
};

class Float32x4 : public AllStatic {
 public:
  static word value_offset();
  static word InstanceSize();
};

class Float64x2 : public AllStatic {
 public:
  static word value_offset();
  static word InstanceSize();
};

class TimelineStream : public AllStatic {
 public:
  static word enabled_offset();
};

class VMHandles : public AllStatic {
 public:
  static constexpr intptr_t kOffsetOfRawPtrInHandle = kWordSize;
};

class Thread : public AllStatic {
 public:
  static word dart_stream_offset();
  static word async_stack_trace_offset();
  static word predefined_symbols_address_offset();
  static word optimize_entry_offset();
  static word deoptimize_entry_offset();
  static word megamorphic_call_checked_entry_offset();
  static word active_exception_offset();
  static word active_stacktrace_offset();
  static word resume_pc_offset();
  static word marking_stack_block_offset();
  static word top_exit_frame_info_offset();
  static word top_resource_offset();
  static word global_object_pool_offset();
  static word object_null_offset();
  static word bool_true_offset();
  static word bool_false_offset();
  static word top_offset();
  static word end_offset();
  static word isolate_offset();
  static word store_buffer_block_offset();
  static word call_to_runtime_entry_point_offset();
  static word null_error_shared_with_fpu_regs_entry_point_offset();
  static word null_error_shared_without_fpu_regs_entry_point_offset();
  static word write_barrier_mask_offset();
  static word monomorphic_miss_entry_offset();
  static word write_barrier_wrappers_thread_offset(Register regno);
  static word array_write_barrier_entry_point_offset();
  static word write_barrier_entry_point_offset();
  static word verify_callback_entry_offset();
  static word vm_tag_offset();
  static uword vm_tag_compiled_id();

  static word safepoint_state_offset();
  static uword safepoint_state_unacquired();
  static uword safepoint_state_acquired();

  static word execution_state_offset();
  static uword vm_execution_state();
  static uword native_execution_state();
  static uword generated_execution_state();
  static word stack_overflow_flags_offset();
  static word stack_overflow_shared_stub_entry_point_offset(bool fpu_regs);
  static word stack_limit_offset();
  static word unboxed_int64_runtime_arg_offset();

  static word callback_code_offset();

  static word AllocateArray_entry_point_offset();
#if !defined(TARGET_ARCH_DBC)
  static word write_barrier_code_offset();
  static word array_write_barrier_code_offset();
  static word fix_callers_target_code_offset();
  static word fix_allocation_stub_code_offset();

  static word monomorphic_miss_stub_offset();
  static word lazy_specialize_type_test_stub_offset();
  static word slow_type_test_stub_offset();
  static word call_to_runtime_stub_offset();
  static word invoke_dart_code_stub_offset();
  static word interpret_call_entry_point_offset();
  static word invoke_dart_code_from_bytecode_stub_offset();
  static word null_error_shared_without_fpu_regs_stub_offset();
  static word null_error_shared_with_fpu_regs_stub_offset();
  static word stack_overflow_shared_without_fpu_regs_entry_point_offset();
  static word stack_overflow_shared_without_fpu_regs_stub_offset();
  static word stack_overflow_shared_with_fpu_regs_entry_point_offset();
  static word stack_overflow_shared_with_fpu_regs_stub_offset();
  static word lazy_deopt_from_return_stub_offset();
  static word lazy_deopt_from_throw_stub_offset();
  static word optimize_stub_offset();
  static word deoptimize_stub_offset();
  static word enter_safepoint_stub_offset();
  static word exit_safepoint_stub_offset();
  static word call_native_through_safepoint_stub_offset();
  static word call_native_through_safepoint_entry_point_offset();
#endif  // !defined(TARGET_ARCH_DBC)

  static word no_scope_native_wrapper_entry_point_offset();
  static word auto_scope_native_wrapper_entry_point_offset();

#define THREAD_XMM_CONSTANT_LIST(V)                                            \
  V(float_not)                                                                 \
  V(float_negate)                                                              \
  V(float_absolute)                                                            \
  V(float_zerow)                                                               \
  V(double_negate)                                                             \
  V(double_abs)

#define DECLARE_CONSTANT_OFFSET_GETTER(name)                                   \
  static word name##_address_offset();
  THREAD_XMM_CONSTANT_LIST(DECLARE_CONSTANT_OFFSET_GETTER)
#undef DECLARE_CONSTANT_OFFSET_GETTER

  static word OffsetFromThread(const dart::Object& object);
  static intptr_t OffsetFromThread(const dart::RuntimeEntry* runtime_entry);
};

class StoreBufferBlock : public AllStatic {
 public:
  static word top_offset();
  static word pointers_offset();
  static const word kSize;
};

class MarkingStackBlock : public AllStatic {
 public:
  static word top_offset();
  static word pointers_offset();
  static const word kSize;
};

class ObjectStore : public AllStatic {
 public:
  static word double_type_offset();
  static word int_type_offset();
  static word string_type_offset();
};

class Isolate : public AllStatic {
 public:
  static word object_store_offset();
  static word default_tag_offset();
  static word current_tag_offset();
  static word user_tag_offset();
  static word class_table_offset();
  static word ic_miss_code_offset();
#if !defined(PRODUCT)
  static word single_step_offset();
#endif  // !defined(PRODUCT)
};

class ClassTable : public AllStatic {
 public:
  static word table_offset();
#if !defined(PRODUCT)
  static word ClassOffsetFor(intptr_t cid);
  static word StateOffsetFor(intptr_t cid);
  static word class_heap_stats_table_offset();
  static word NewSpaceCounterOffsetFor(intptr_t cid);
  static word NewSpaceSizeOffsetFor(intptr_t cid);
#endif  // !defined(PRODUCT)
  static const word kSizeOfClassPairLog2;
};

#if !defined(PRODUCT)
class ClassHeapStats : public AllStatic {
 public:
  static word TraceAllocationMask();
  static word state_offset();
  static word allocated_since_gc_new_space_offset();
  static word allocated_size_since_gc_new_space_offset();
};
#endif  // !defined(PRODUCT)

class Instructions : public AllStatic {
 public:
  static const word kMonomorphicEntryOffsetJIT;
  static const word kPolymorphicEntryOffsetJIT;
  static const word kMonomorphicEntryOffsetAOT;
  static const word kPolymorphicEntryOffsetAOT;
  static word HeaderSize();
  static word UnalignedHeaderSize();
};

class Code : public AllStatic {
 public:
#if defined(TARGET_ARCH_IA32)
  static uword EntryPointOf(const dart::Code& code);
#endif  // defined(TARGET_ARCH_IA32)

  static word object_pool_offset();
  static word entry_point_offset(CodeEntryKind kind = CodeEntryKind::kNormal);
  static word function_entry_point_offset(CodeEntryKind kind);
  static word saved_instructions_offset();
  static word owner_offset();
};

class SubtypeTestCache : public AllStatic {
 public:
  static word cache_offset();

  static const word kTestEntryLength;
  static const word kInstanceClassIdOrFunction;
  static const word kInstanceTypeArguments;
  static const word kInstantiatorTypeArguments;
  static const word kFunctionTypeArguments;
  static const word kInstanceParentFunctionTypeArguments;
  static const word kInstanceDelayedFunctionTypeArguments;
  static const word kTestResult;
};

class Context : public AllStatic {
 public:
  static word header_size();
  static word parent_offset();
  static word num_variables_offset();
  static word variable_offset(word i);
  static word InstanceSize(word n);
};

class Closure : public AllStatic {
 public:
  static word context_offset();
  static word delayed_type_arguments_offset();
  static word function_offset();
  static word function_type_arguments_offset();
  static word instantiator_type_arguments_offset();
  static word hash_offset();
  static word InstanceSize();
};

class HeapPage : public AllStatic {
 public:
  static const word kBytesPerCardLog2;

  static word card_table_offset();
};

class Heap : public AllStatic {
 public:
  // Return true if an object with the given instance size is allocatable
  // in new space on the target.
  static bool IsAllocatableInNewSpace(intptr_t instance_size);
};

class NativeArguments {
 public:
  static word thread_offset();
  static word argc_tag_offset();
  static word argv_offset();
  static word retval_offset();

  static word StructSize();
};

class NativeEntry {
 public:
  static const word kNumCallWrapperArguments;
};

class RegExp : public AllStatic {
 public:
  static word function_offset(classid_t cid, bool sticky);
};

class UserTag : public AllStatic {
 public:
  static word tag_offset();
};

class Symbols : public AllStatic {
 public:
  static const word kNumberOfOneCharCodeSymbols;
  static const word kNullCharCodeSymbolOffset;
};

class Field : public AllStatic {
 public:
  static word OffsetOf(const dart::Field& field);

  static word guarded_cid_offset();
  static word guarded_list_length_in_object_offset_offset();
  static word guarded_list_length_offset();
  static word is_nullable_offset();
  static word static_value_offset();
  static word kind_bits_offset();
};

class TypeArguments : public AllStatic {
 public:
  static word instantiations_offset();
  static word type_at_offset(intptr_t i);
};

}  // namespace target
}  // namespace compiler
}  // namespace dart

#endif  // RUNTIME_VM_COMPILER_RUNTIME_API_H_
