// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#if !defined(DART_PRECOMPILED_RUNTIME)

#include "vm/compiler/backend/il.h"

#include "vm/bit_vector.h"
#include "vm/bootstrap.h"
#include "vm/compiler/backend/code_statistics.h"
#include "vm/compiler/backend/constant_propagator.h"
#include "vm/compiler/backend/flow_graph_compiler.h"
#include "vm/compiler/backend/linearscan.h"
#include "vm/compiler/backend/locations.h"
#include "vm/compiler/backend/loops.h"
#include "vm/compiler/backend/range_analysis.h"
#include "vm/compiler/ffi.h"
#include "vm/compiler/frontend/flow_graph_builder.h"
#include "vm/compiler/jit/compiler.h"
#include "vm/compiler/method_recognizer.h"
#include "vm/cpu.h"
#include "vm/dart_entry.h"
#include "vm/object.h"
#include "vm/object_store.h"
#include "vm/os.h"
#include "vm/regexp_assembler_ir.h"
#include "vm/resolver.h"
#include "vm/scopes.h"
#include "vm/stack_frame.h"
#include "vm/stub_code.h"
#include "vm/symbols.h"
#include "vm/type_testing_stubs.h"

#include "vm/compiler/backend/il_printer.h"

namespace dart {

DEFINE_FLAG(bool,
            propagate_ic_data,
            true,
            "Propagate IC data from unoptimized to optimized IC calls.");
DEFINE_FLAG(bool,
            two_args_smi_icd,
            true,
            "Generate special IC stubs for two args Smi operations");
DEFINE_FLAG(bool,
            unbox_numeric_fields,
            !USING_DBC,
            "Support unboxed double and float32x4 fields.");

class SubclassFinder {
 public:
  SubclassFinder(Zone* zone,
                 GrowableArray<intptr_t>* cids,
                 bool include_abstract)
      : array_handles_(zone),
        class_handles_(zone),
        cids_(cids),
        include_abstract_(include_abstract) {}

  void ScanSubClasses(const Class& klass) {
    if (include_abstract_ || !klass.is_abstract()) {
      cids_->Add(klass.id());
    }
    ScopedHandle<GrowableObjectArray> array(&array_handles_);
    ScopedHandle<Class> subclass(&class_handles_);
    *array = klass.direct_subclasses();
    if (!array->IsNull()) {
      for (intptr_t i = 0; i < array->Length(); ++i) {
        *subclass ^= array->At(i);
        ScanSubClasses(*subclass);
      }
    }
  }

  void ScanImplementorClasses(const Class& klass) {
    // An implementor of [klass] is
    //    * the [klass] itself.
    //    * all implementors of the direct subclasses of [klass].
    //    * all implementors of the direct implementors of [klass].
    if (include_abstract_ || !klass.is_abstract()) {
      cids_->Add(klass.id());
    }

    ScopedHandle<GrowableObjectArray> array(&array_handles_);
    ScopedHandle<Class> subclass_or_implementor(&class_handles_);

    *array = klass.direct_subclasses();
    if (!array->IsNull()) {
      for (intptr_t i = 0; i < array->Length(); ++i) {
        *subclass_or_implementor ^= (*array).At(i);
        ScanImplementorClasses(*subclass_or_implementor);
      }
    }
    *array = klass.direct_implementors();
    if (!array->IsNull()) {
      for (intptr_t i = 0; i < array->Length(); ++i) {
        *subclass_or_implementor ^= (*array).At(i);
        ScanImplementorClasses(*subclass_or_implementor);
      }
    }
  }

 private:
  ReusableHandleStack<GrowableObjectArray> array_handles_;
  ReusableHandleStack<Class> class_handles_;
  GrowableArray<intptr_t>* cids_;
  const bool include_abstract_;
};

const CidRangeVector& HierarchyInfo::SubtypeRangesForClass(
    const Class& klass,
    bool include_abstract,
    bool exclude_null) {
  ClassTable* table = thread()->isolate()->class_table();
  const intptr_t cid_count = table->NumCids();
  CidRangeVector** cid_ranges = nullptr;
  if (include_abstract) {
    ASSERT(!exclude_null);
    cid_ranges = &cid_subtype_ranges_abstract_nullable_;
  } else if (exclude_null) {
    ASSERT(!include_abstract);
    cid_ranges = &cid_subtype_ranges_nonnullable_;
  } else {
    ASSERT(!include_abstract);
    ASSERT(!exclude_null);
    cid_ranges = &cid_subtype_ranges_nullable_;
  }
  if (*cid_ranges == nullptr) {
    *cid_ranges = new CidRangeVector[cid_count];
  }
  CidRangeVector& ranges = (*cid_ranges)[klass.id()];
  if (ranges.length() == 0) {
    if (!FLAG_precompiled_mode) {
      BuildRangesForJIT(table, &ranges, klass, /*use_subtype_test=*/true,
                        include_abstract, exclude_null);
    } else {
      BuildRangesFor(table, &ranges, klass, /*use_subtype_test=*/true,
                     include_abstract, exclude_null);
    }
  }
  return ranges;
}

const CidRangeVector& HierarchyInfo::SubclassRangesForClass(
    const Class& klass) {
  ClassTable* table = thread()->isolate()->class_table();
  const intptr_t cid_count = table->NumCids();
  if (cid_subclass_ranges_ == NULL) {
    cid_subclass_ranges_ = new CidRangeVector[cid_count];
  }

  CidRangeVector& ranges = cid_subclass_ranges_[klass.id()];
  if (ranges.length() == 0) {
    if (!FLAG_precompiled_mode) {
      BuildRangesForJIT(table, &ranges, klass,
                        /*use_subtype_test=*/true,
                        /*include_abstract=*/false,
                        /*exclude_null=*/false);
    } else {
      BuildRangesFor(table, &ranges, klass,
                     /*use_subtype_test=*/false,
                     /*include_abstract=*/false,
                     /*exclude_null=*/false);
    }
  }
  return ranges;
}

// Build the ranges either for:
//    "<obj> as <Type>", or
//    "<obj> is <Type>"
void HierarchyInfo::BuildRangesFor(ClassTable* table,
                                   CidRangeVector* ranges,
                                   const Class& klass,
                                   bool use_subtype_test,
                                   bool include_abstract,
                                   bool exclude_null) {
  Zone* zone = thread()->zone();
  ClassTable* class_table = thread()->isolate()->class_table();

  // Only really used if `use_subtype_test == true`.
  const Type& dst_type = Type::Handle(zone, Type::RawCast(klass.RareType()));
  AbstractType& cls_type = AbstractType::Handle(zone);

  Class& cls = Class::Handle(zone);
  AbstractType& super_type = AbstractType::Handle(zone);
  const intptr_t cid_count = table->NumCids();

  // Iterate over all cids to find the ones to be included in the ranges.
  intptr_t start = -1;
  intptr_t end = -1;
  for (intptr_t cid = kInstanceCid; cid < cid_count; ++cid) {
    // Create local zone because deep hierarchies may allocate lots of handles
    // within one iteration of this loop.
    StackZone stack_zone(thread());
    HANDLESCOPE(thread());

    // Some cases are "don't care", i.e., they may or may not be included,
    // whatever yields the least number of ranges for efficiency.
    if (!table->HasValidClassAt(cid)) continue;
    if (cid == kTypeArgumentsCid) continue;
    if (cid == kVoidCid) continue;
    if (cid == kDynamicCid) continue;
    if (cid == kNullCid && !exclude_null) continue;
    cls = table->At(cid);
    if (!include_abstract && cls.is_abstract()) continue;
    if (cls.is_patch()) continue;
    if (cls.IsTopLevel()) continue;

    // We are either interested in [CidRange]es of subclasses or subtypes.
    bool test_succeeded = false;
    if (cid == kNullCid) {
      ASSERT(exclude_null);
      test_succeeded = false;
    } else if (use_subtype_test) {
      cls_type = cls.RareType();
      test_succeeded = cls_type.IsSubtypeOf(dst_type, Heap::kNew);
    } else {
      while (!cls.IsObjectClass()) {
        if (cls.raw() == klass.raw()) {
          test_succeeded = true;
          break;
        }
        super_type = cls.super_type();
        const intptr_t type_class_id = super_type.type_class_id();
        cls = class_table->At(type_class_id);
      }
    }

    if (test_succeeded) {
      // On success, open a new or continue any open range.
      if (start == -1) start = cid;
      end = cid;
    } else if (start != -1) {
      // On failure, close any open range from start to end
      // (the latter is the most recent succesful "do-care" cid).
      ASSERT(start <= end);
      CidRange range(start, end);
      ranges->Add(range);
      start = -1;
      end = -1;
    }
  }

  // Construct last range (either close open one, or add invalid).
  if (start != -1) {
    ASSERT(start <= end);
    CidRange range(start, end);
    ranges->Add(range);
  } else if (ranges->length() == 0) {
    CidRange range;
    ASSERT(range.IsIllegalRange());
    ranges->Add(range);
  }
}

void HierarchyInfo::BuildRangesForJIT(ClassTable* table,
                                      CidRangeVector* ranges,
                                      const Class& dst_klass,
                                      bool use_subtype_test,
                                      bool include_abstract,
                                      bool exclude_null) {
  if (dst_klass.InVMIsolateHeap()) {
    BuildRangesFor(table, ranges, dst_klass, use_subtype_test, include_abstract,
                   exclude_null);
    return;
  }
  ASSERT(!exclude_null);

  Zone* zone = thread()->zone();
  GrowableArray<intptr_t> cids;
  SubclassFinder finder(zone, &cids, include_abstract);
  if (use_subtype_test) {
    finder.ScanImplementorClasses(dst_klass);
  } else {
    finder.ScanSubClasses(dst_klass);
  }

  // Sort all collected cids.
  intptr_t* cids_array = cids.data();

  qsort(cids_array, cids.length(), sizeof(intptr_t),
        [](const void* a, const void* b) {
          return static_cast<int>(*static_cast<const intptr_t*>(a) -
                                  *static_cast<const intptr_t*>(b));
        });

  // Build ranges of all the cids.
  Class& klass = Class::Handle();
  intptr_t left_cid = -1;
  intptr_t last_cid = -1;
  for (intptr_t i = 0; i < cids.length(); ++i) {
    if (left_cid == -1) {
      left_cid = last_cid = cids[i];
    } else {
      const intptr_t current_cid = cids[i];

      // Skip duplicates.
      if (current_cid == last_cid) continue;

      // Consecutive numbers cids are ok.
      if (current_cid == (last_cid + 1)) {
        last_cid = current_cid;
      } else {
        // We sorted, after all!
        RELEASE_ASSERT(last_cid < current_cid);

        intptr_t j = last_cid + 1;
        for (; j < current_cid; ++j) {
          if (table->HasValidClassAt(j)) {
            klass = table->At(j);
            if (!klass.is_patch() && !klass.IsTopLevel()) {
              // If we care about abstract classes also, we cannot skip over any
              // arbitrary abstract class, only those which are subtypes.
              if (include_abstract) {
                break;
              }

              // If the class is concrete we cannot skip over it.
              if (!klass.is_abstract()) {
                break;
              }
            }
          }
        }

        if (current_cid == j) {
          // If there's only abstract cids between [last_cid] and the
          // [current_cid] then we connect them.
          last_cid = current_cid;
        } else {
          // Finish the current open cid range and start a new one.
          ranges->Add(CidRange{left_cid, last_cid});
          left_cid = last_cid = current_cid;
        }
      }
    }
  }

  // If there is an open cid-range which we haven't finished yet, we'll
  // complete it.
  if (left_cid != -1) {
    ranges->Add(CidRange{left_cid, last_cid});
  }
}

bool HierarchyInfo::CanUseSubtypeRangeCheckFor(const AbstractType& type) {
  ASSERT(type.IsFinalized());

  if (!type.IsInstantiated() || !type.IsType() || type.IsFunctionType() ||
      type.IsDartFunctionType()) {
    return false;
  }

  Zone* zone = thread()->zone();
  const Class& type_class = Class::Handle(zone, type.type_class());

  // The FutureOr<T> type cannot be handled by checking whether the instance is
  // a subtype of FutureOr and then checking whether the type argument `T`
  // matches.
  //
  // Instead we would need to perform multiple checks:
  //
  //    instance is Null || instance is T || instance is Future<T>
  //
  if (type_class.IsFutureOrClass()) {
    return false;
  }

  // We can use class id range checks only if we don't have to test type
  // arguments.
  //
  // This is e.g. true for "String" but also for "List<dynamic>".  (A type for
  // which the type arguments vector is filled with "dynamic" is known as a rare
  // type)
  if (type_class.IsGeneric()) {
    // TODO(kustermann): We might want to consider extending this when the type
    // arguments are not "dynamic" but instantiated-to-bounds.
    const Type& rare_type =
        Type::Handle(zone, Type::RawCast(type_class.RareType()));
    if (!rare_type.Equals(type)) {
      return false;
    }
  }

  return true;
}

bool HierarchyInfo::CanUseGenericSubtypeRangeCheckFor(
    const AbstractType& type) {
  ASSERT(type.IsFinalized());

  if (!type.IsType() || type.IsFunctionType() || type.IsDartFunctionType()) {
    return false;
  }

  // NOTE: We do allow non-instantiated types here (in comparison to
  // [CanUseSubtypeRangeCheckFor], since we handle type parameters in the type
  // expression in some cases (see below).

  Zone* zone = thread()->zone();
  const Class& type_class = Class::Handle(zone, type.type_class());
  const intptr_t num_type_parameters = type_class.NumTypeParameters();
  const intptr_t num_type_arguments = type_class.NumTypeArguments();

  // The FutureOr<T> type cannot be handled by checking whether the instance is
  // a subtype of FutureOr and then checking whether the type argument `T`
  // matches.
  //
  // Instead we would need to perform multiple checks:
  //
  //    instance is Null || instance is T || instance is Future<T>
  //
  if (type_class.IsFutureOrClass()) {
    return false;
  }

  // This function should only be called for generic classes.
  ASSERT(type_class.NumTypeParameters() > 0 &&
         type.arguments() != TypeArguments::null());

  // If the type class is implemented the different implementations might have
  // their type argument vector stored at different offsets and we can therefore
  // not perform our optimized [CidRange]-based implementation.
  //
  // TODO(kustermann): If the class is implemented but all implementations
  // store the instantator type argument vector at the same offset we can
  // still do it!
  if (type_class.is_implemented()) {
    return false;
  }

  const TypeArguments& ta =
      TypeArguments::Handle(zone, Type::Cast(type).arguments());
  ASSERT(ta.Length() == num_type_arguments);

  // The last [num_type_pararameters] entries in the [TypeArguments] vector [ta]
  // are the values we have to check against.  Ensure we can handle all of them
  // via [CidRange]-based checks or that it is a type parameter.
  AbstractType& type_arg = AbstractType::Handle(zone);
  for (intptr_t i = 0; i < num_type_parameters; ++i) {
    type_arg = ta.TypeAt(num_type_arguments - num_type_parameters + i);
    if (!CanUseSubtypeRangeCheckFor(type_arg) && !type_arg.IsTypeParameter()) {
      return false;
    }
  }

  return true;
}

bool HierarchyInfo::InstanceOfHasClassRange(const AbstractType& type,
                                            intptr_t* lower_limit,
                                            intptr_t* upper_limit) {
  ASSERT(FLAG_precompiled_mode);
  if (CanUseSubtypeRangeCheckFor(type)) {
    const Class& type_class =
        Class::Handle(thread()->zone(), type.type_class());
    const CidRangeVector& ranges =
        SubtypeRangesForClass(type_class,
                              /*include_abstract=*/false,
                              /*exclude_null=*/true);
    if (ranges.length() == 1) {
      const CidRange& range = ranges[0];
      if (!range.IsIllegalRange()) {
        *lower_limit = range.cid_start;
        *upper_limit = range.cid_end;
        return true;
      }
    }
  }
  return false;
}

#if defined(DEBUG)
void Instruction::CheckField(const Field& field) const {
  ASSERT(field.IsZoneHandle());
  ASSERT(!Compiler::IsBackgroundCompilation() || !field.IsOriginal());
}
#endif  // DEBUG

Definition::Definition(intptr_t deopt_id) : Instruction(deopt_id) {}

// A value in the constant propagation lattice.
//    - non-constant sentinel
//    - a constant (any non-sentinel value)
//    - unknown sentinel
Object& Definition::constant_value() {
  if (constant_value_ == NULL) {
    constant_value_ = &Object::ZoneHandle(ConstantPropagator::Unknown());
  }
  return *constant_value_;
}

Definition* Definition::OriginalDefinition() {
  Definition* defn = this;
  Value* unwrapped;
  while ((unwrapped = defn->RedefinedValue()) != nullptr) {
    defn = unwrapped->definition();
  }
  return defn;
}

Value* Definition::RedefinedValue() const {
  return nullptr;
}

Value* RedefinitionInstr::RedefinedValue() const {
  return value();
}

Value* AssertAssignableInstr::RedefinedValue() const {
  return value();
}

Value* CheckBoundBase::RedefinedValue() const {
  return index();
}

Value* CheckNullInstr::RedefinedValue() const {
  return value();
}

Definition* Definition::OriginalDefinitionIgnoreBoxingAndConstraints() {
  Definition* def = this;
  while (true) {
    Definition* orig;
    if (def->IsConstraint() || def->IsBox() || def->IsUnbox()) {
      orig = def->InputAt(0)->definition();
    } else {
      orig = def->OriginalDefinition();
    }
    if (orig == def) return def;
    def = orig;
  }
}

const ICData* Instruction::GetICData(
    const ZoneGrowableArray<const ICData*>& ic_data_array) const {
  // The deopt_id can be outside the range of the IC data array for
  // computations added in the optimizing compiler.
  ASSERT(deopt_id_ != DeoptId::kNone);
  if (deopt_id_ < ic_data_array.length()) {
    const ICData* result = ic_data_array[deopt_id_];
#if defined(DEBUG)
    if (result != NULL) {
      switch (tag()) {
        case kInstanceCall:
          if (result->is_static_call()) {
            FATAL("ICData tag mismatch");
          }
          break;
        case kStaticCall:
          if (!result->is_static_call()) {
            FATAL("ICData tag mismatch");
          }
          break;
        default:
          UNREACHABLE();
      }
    }
#endif
    return result;
  }
  return NULL;
}

intptr_t Instruction::Hashcode() const {
  intptr_t result = tag();
  for (intptr_t i = 0; i < InputCount(); ++i) {
    Value* value = InputAt(i);
    intptr_t j = value->definition()->ssa_temp_index();
    result = result * 31 + j;
  }
  return result;
}

bool Instruction::Equals(Instruction* other) const {
  if (tag() != other->tag()) return false;
  if (InputCount() != other->InputCount()) return false;
  for (intptr_t i = 0; i < InputCount(); ++i) {
    if (!InputAt(i)->Equals(other->InputAt(i))) return false;
  }
  return AttributesEqual(other);
}

void Instruction::Unsupported(FlowGraphCompiler* compiler) {
  compiler->Bailout(ToCString());
  UNREACHABLE();
}

bool Value::Equals(Value* other) const {
  return definition() == other->definition();
}

static int OrderById(CidRange* const* a, CidRange* const* b) {
  // Negative if 'a' should sort before 'b'.
  ASSERT((*a)->IsSingleCid());
  ASSERT((*b)->IsSingleCid());
  return (*a)->cid_start - (*b)->cid_start;
}

static int OrderByFrequency(CidRange* const* a, CidRange* const* b) {
  const TargetInfo* target_info_a = static_cast<const TargetInfo*>(*a);
  const TargetInfo* target_info_b = static_cast<const TargetInfo*>(*b);
  // Negative if 'a' should sort before 'b'.
  return target_info_b->count - target_info_a->count;
}

bool Cids::Equals(const Cids& other) const {
  if (length() != other.length()) return false;
  for (int i = 0; i < length(); i++) {
    if (cid_ranges_[i]->cid_start != other.cid_ranges_[i]->cid_start ||
        cid_ranges_[i]->cid_end != other.cid_ranges_[i]->cid_end) {
      return false;
    }
  }
  return true;
}

intptr_t Cids::ComputeLowestCid() const {
  intptr_t min = kIntptrMax;
  for (intptr_t i = 0; i < cid_ranges_.length(); ++i) {
    min = Utils::Minimum(min, cid_ranges_[i]->cid_start);
  }
  return min;
}

intptr_t Cids::ComputeHighestCid() const {
  intptr_t max = -1;
  for (intptr_t i = 0; i < cid_ranges_.length(); ++i) {
    max = Utils::Maximum(max, cid_ranges_[i]->cid_end);
  }
  return max;
}

bool Cids::HasClassId(intptr_t cid) const {
  for (int i = 0; i < length(); i++) {
    if (cid_ranges_[i]->Contains(cid)) {
      return true;
    }
  }
  return false;
}

Cids* Cids::CreateMonomorphic(Zone* zone, intptr_t cid) {
  Cids* cids = new (zone) Cids(zone);
  cids->Add(new (zone) CidRange(cid, cid));
  return cids;
}

Cids* Cids::CreateAndExpand(Zone* zone,
                            const ICData& ic_data,
                            int argument_number) {
  Cids* cids = new (zone) Cids(zone);
  cids->CreateHelper(zone, ic_data, argument_number,
                     /* include_targets = */ false);
  cids->Sort(OrderById);

  // Merge adjacent class id ranges.
  {
    int dest = 0;
    for (int src = 1; src < cids->length(); src++) {
      if (cids->cid_ranges_[dest]->cid_end + 1 >=
          cids->cid_ranges_[src]->cid_start) {
        cids->cid_ranges_[dest]->cid_end = cids->cid_ranges_[src]->cid_end;
      } else {
        dest++;
        if (src != dest) cids->cid_ranges_[dest] = cids->cid_ranges_[src];
      }
    }
    cids->SetLength(dest + 1);
  }

  // Merging/extending cid ranges is also done in CallTargets::CreateAndExpand.
  // If changing this code, consider also adjusting CallTargets code.

  if (cids->length() > 1 && argument_number == 0 && ic_data.HasOneTarget()) {
    // Try harder to merge ranges if method lookups in the gaps result in the
    // same target method.
    const Function& target = Function::Handle(zone, ic_data.GetTargetAt(0));
    if (!MethodRecognizer::PolymorphicTarget(target)) {
      const auto& args_desc_array =
          Array::Handle(zone, ic_data.arguments_descriptor());
      ArgumentsDescriptor args_desc(args_desc_array);
      const auto& name = String::Handle(zone, ic_data.target_name());
      auto& fn = Function::Handle(zone);

      intptr_t dest = 0;
      for (intptr_t src = 1; src < cids->length(); src++) {
        // Inspect all cids in the gap and see if they all resolve to the same
        // target.
        bool can_merge = true;
        for (intptr_t cid = cids->cid_ranges_[dest]->cid_end + 1,
                      end = cids->cid_ranges_[src]->cid_start;
             cid < end; ++cid) {
          bool class_is_abstract = false;
          if (FlowGraphCompiler::LookupMethodFor(cid, name, args_desc, &fn,
                                                 &class_is_abstract)) {
            if (fn.raw() == target.raw()) {
              continue;
            }
            if (class_is_abstract) {
              continue;
            }
          }
          can_merge = false;
          break;
        }

        if (can_merge) {
          cids->cid_ranges_[dest]->cid_end = cids->cid_ranges_[src]->cid_end;
        } else {
          dest++;
          if (src != dest) cids->cid_ranges_[dest] = cids->cid_ranges_[src];
        }
      }
      cids->SetLength(dest + 1);
    }
  }

  return cids;
}

static intptr_t Usage(const Function& function) {
  intptr_t count = function.usage_counter();
  if (count < 0) {
    if (function.HasCode()) {
      // 'function' is queued for optimized compilation
      count = FLAG_optimization_counter_threshold;
    } else {
      // 'function' is queued for unoptimized compilation
      count = FLAG_compilation_counter_threshold;
    }
  } else if (Code::IsOptimized(function.CurrentCode())) {
    // 'function' was optimized and stopped counting
    count = FLAG_optimization_counter_threshold;
  }
  return count;
}

void Cids::CreateHelper(Zone* zone,
                        const ICData& ic_data,
                        int argument_number,
                        bool include_targets) {
  ASSERT(argument_number < ic_data.NumArgsTested());

  if (ic_data.NumberOfChecks() == 0) return;

  Function& dummy = Function::Handle(zone);

  bool check_one_arg = ic_data.NumArgsTested() == 1;

  int checks = ic_data.NumberOfChecks();
  for (int i = 0; i < checks; i++) {
    if (ic_data.GetCountAt(i) == 0) continue;
    intptr_t id = 0;
    if (check_one_arg) {
      ic_data.GetOneClassCheckAt(i, &id, &dummy);
    } else {
      GrowableArray<intptr_t> arg_ids;
      ic_data.GetCheckAt(i, &arg_ids, &dummy);
      id = arg_ids[argument_number];
    }
    if (include_targets) {
      Function& function = Function::ZoneHandle(zone, ic_data.GetTargetAt(i));
      intptr_t count = ic_data.GetCountAt(i);
      cid_ranges_.Add(new (zone) TargetInfo(id, id, &function, count,
                                            ic_data.GetExactnessAt(i)));
    } else {
      cid_ranges_.Add(new (zone) CidRange(id, id));
    }
  }

  if (ic_data.is_megamorphic()) {
    const MegamorphicCache& cache =
        MegamorphicCache::Handle(zone, ic_data.AsMegamorphicCache());
    SafepointMutexLocker ml(Isolate::Current()->megamorphic_mutex());
    MegamorphicCacheEntries entries(Array::Handle(zone, cache.buckets()));
    for (intptr_t i = 0; i < entries.Length(); i++) {
      const intptr_t id =
          Smi::Value(entries[i].Get<MegamorphicCache::kClassIdIndex>());
      if (id == kIllegalCid) {
        continue;
      }
      if (include_targets) {
        Function& function = Function::ZoneHandle(zone);
        function ^= entries[i].Get<MegamorphicCache::kTargetFunctionIndex>();
        const intptr_t filled_entry_count = cache.filled_entry_count();
        ASSERT(filled_entry_count > 0);
        cid_ranges_.Add(new (zone) TargetInfo(
            id, id, &function, Usage(function) / filled_entry_count,
            StaticTypeExactnessState::NotTracking()));
      } else {
        cid_ranges_.Add(new (zone) CidRange(id, id));
      }
    }
  }
}

bool Cids::IsMonomorphic() const {
  if (length() != 1) return false;
  return cid_ranges_[0]->IsSingleCid();
}

intptr_t Cids::MonomorphicReceiverCid() const {
  ASSERT(IsMonomorphic());
  return cid_ranges_[0]->cid_start;
}

CheckClassInstr::CheckClassInstr(Value* value,
                                 intptr_t deopt_id,
                                 const Cids& cids,
                                 TokenPosition token_pos)
    : TemplateInstruction(deopt_id),
      cids_(cids),
      licm_hoisted_(false),
      is_bit_test_(IsCompactCidRange(cids)),
      token_pos_(token_pos) {
  // Expected useful check data.
  const intptr_t number_of_checks = cids.length();
  ASSERT(number_of_checks > 0);
  SetInputAt(0, value);
  // Otherwise use CheckSmiInstr.
  ASSERT(number_of_checks != 1 || !cids[0].IsSingleCid() ||
         cids[0].cid_start != kSmiCid);
}

bool CheckClassInstr::AttributesEqual(Instruction* other) const {
  CheckClassInstr* other_check = other->AsCheckClass();
  ASSERT(other_check != NULL);
  return cids().Equals(other_check->cids());
}

bool CheckClassInstr::IsDeoptIfNull() const {
  if (!cids().IsMonomorphic()) {
    return false;
  }
  CompileType* in_type = value()->Type();
  const intptr_t cid = cids().MonomorphicReceiverCid();
  // Performance check: use CheckSmiInstr instead.
  ASSERT(cid != kSmiCid);
  return in_type->is_nullable() && (in_type->ToNullableCid() == cid);
}

// Null object is a singleton of null-class (except for some sentinel,
// transitional temporaries). Instead of checking against the null class only
// we can check against null instance instead.
bool CheckClassInstr::IsDeoptIfNotNull() const {
  if (!cids().IsMonomorphic()) {
    return false;
  }
  const intptr_t cid = cids().MonomorphicReceiverCid();
  return cid == kNullCid;
}

bool CheckClassInstr::IsCompactCidRange(const Cids& cids) {
  const intptr_t number_of_checks = cids.length();
  // If there are only two checks, the extra register pressure needed for the
  // dense-cid-range code is not justified.
  if (number_of_checks <= 2) return false;

  // TODO(fschneider): Support smis in dense cid checks.
  if (cids.HasClassId(kSmiCid)) return false;

  intptr_t min = cids.ComputeLowestCid();
  intptr_t max = cids.ComputeHighestCid();
  return (max - min) < compiler::target::kBitsPerWord;
}

bool CheckClassInstr::IsBitTest() const {
  return is_bit_test_;
}

intptr_t CheckClassInstr::ComputeCidMask() const {
  ASSERT(IsBitTest());
  intptr_t min = cids_.ComputeLowestCid();
  intptr_t mask = 0;
  for (intptr_t i = 0; i < cids_.length(); ++i) {
    intptr_t run;
    uintptr_t range = 1ul + cids_[i].Extent();
    if (range >= static_cast<uintptr_t>(compiler::target::kBitsPerWord)) {
      run = -1;
    } else {
      run = (1 << range) - 1;
    }
    mask |= run << (cids_[i].cid_start - min);
  }
  return mask;
}

bool LoadFieldInstr::IsUnboxedLoad() const {
  return FLAG_unbox_numeric_fields && slot().IsDartField() &&
         FlowGraphCompiler::IsUnboxedField(slot().field());
}

bool LoadFieldInstr::IsPotentialUnboxedLoad() const {
  return FLAG_unbox_numeric_fields && slot().IsDartField() &&
         FlowGraphCompiler::IsPotentialUnboxedField(slot().field());
}

Representation LoadFieldInstr::representation() const {
  if (IsUnboxedLoad()) {
    const intptr_t cid = slot().field().UnboxedFieldCid();
    switch (cid) {
      case kDoubleCid:
        return kUnboxedDouble;
      case kFloat32x4Cid:
        return kUnboxedFloat32x4;
      case kFloat64x2Cid:
        return kUnboxedFloat64x2;
      default:
        UNREACHABLE();
    }
  }
  return kTagged;
}

bool StoreInstanceFieldInstr::IsUnboxedStore() const {
  return FLAG_unbox_numeric_fields && slot().IsDartField() &&
         FlowGraphCompiler::IsUnboxedField(slot().field());
}

bool StoreInstanceFieldInstr::IsPotentialUnboxedStore() const {
  return FLAG_unbox_numeric_fields && slot().IsDartField() &&
         FlowGraphCompiler::IsPotentialUnboxedField(slot().field());
}

Representation StoreInstanceFieldInstr::RequiredInputRepresentation(
    intptr_t index) const {
  ASSERT((index == 0) || (index == 1));
  if ((index == 1) && IsUnboxedStore()) {
    const intptr_t cid = slot().field().UnboxedFieldCid();
    switch (cid) {
      case kDoubleCid:
        return kUnboxedDouble;
      case kFloat32x4Cid:
        return kUnboxedFloat32x4;
      case kFloat64x2Cid:
        return kUnboxedFloat64x2;
      default:
        UNREACHABLE();
    }
  }
  return kTagged;
}

bool GuardFieldClassInstr::AttributesEqual(Instruction* other) const {
  return field().raw() == other->AsGuardFieldClass()->field().raw();
}

bool GuardFieldLengthInstr::AttributesEqual(Instruction* other) const {
  return field().raw() == other->AsGuardFieldLength()->field().raw();
}

bool GuardFieldTypeInstr::AttributesEqual(Instruction* other) const {
  return field().raw() == other->AsGuardFieldType()->field().raw();
}

bool AssertAssignableInstr::AttributesEqual(Instruction* other) const {
  AssertAssignableInstr* other_assert = other->AsAssertAssignable();
  ASSERT(other_assert != NULL);
  // This predicate has to be commutative for DominatorBasedCSE to work.
  // TODO(fschneider): Eliminate more asserts with subtype relation.
  return dst_type().raw() == other_assert->dst_type().raw();
}

Instruction* AssertSubtypeInstr::Canonicalize(FlowGraph* flow_graph) {
  // If all values for type parameters are known (i.e. from instantiator and
  // function) we can instantiate the sub and super type and remove this
  // instruction if the subtype test succeeds.
  ConstantInstr* constant_instantiator_type_args =
      instantiator_type_arguments()->definition()->AsConstant();
  ConstantInstr* constant_function_type_args =
      function_type_arguments()->definition()->AsConstant();
  if ((constant_instantiator_type_args != NULL) &&
      (constant_function_type_args != NULL)) {
    ASSERT(constant_instantiator_type_args->value().IsNull() ||
           constant_instantiator_type_args->value().IsTypeArguments());
    ASSERT(constant_function_type_args->value().IsNull() ||
           constant_function_type_args->value().IsTypeArguments());

    Zone* Z = Thread::Current()->zone();
    const TypeArguments& instantiator_type_args = TypeArguments::Handle(
        Z,
        TypeArguments::RawCast(constant_instantiator_type_args->value().raw()));

    const TypeArguments& function_type_args = TypeArguments::Handle(
        Z, TypeArguments::RawCast(constant_function_type_args->value().raw()));

    AbstractType& sub_type = AbstractType::Handle(Z, sub_type_.raw());
    AbstractType& super_type = AbstractType::Handle(Z, super_type_.raw());
    if (AbstractType::InstantiateAndTestSubtype(&sub_type, &super_type,
                                                instantiator_type_args,
                                                function_type_args)) {
      return NULL;
    }
  }
  return this;
}

bool AssertSubtypeInstr::AttributesEqual(Instruction* other) const {
  AssertSubtypeInstr* other_assert = other->AsAssertSubtype();
  ASSERT(other_assert != NULL);
  return super_type().raw() == other_assert->super_type().raw() &&
         sub_type().raw() == other_assert->sub_type().raw();
}

bool StrictCompareInstr::AttributesEqual(Instruction* other) const {
  StrictCompareInstr* other_op = other->AsStrictCompare();
  ASSERT(other_op != NULL);
  return ComparisonInstr::AttributesEqual(other) &&
         (needs_number_check() == other_op->needs_number_check());
}

bool MathMinMaxInstr::AttributesEqual(Instruction* other) const {
  MathMinMaxInstr* other_op = other->AsMathMinMax();
  ASSERT(other_op != NULL);
  return (op_kind() == other_op->op_kind()) &&
         (result_cid() == other_op->result_cid());
}

bool BinaryIntegerOpInstr::AttributesEqual(Instruction* other) const {
  ASSERT(other->tag() == tag());
  BinaryIntegerOpInstr* other_op = other->AsBinaryIntegerOp();
  return (op_kind() == other_op->op_kind()) &&
         (can_overflow() == other_op->can_overflow()) &&
         (is_truncating() == other_op->is_truncating());
}

bool LoadFieldInstr::AttributesEqual(Instruction* other) const {
  LoadFieldInstr* other_load = other->AsLoadField();
  ASSERT(other_load != NULL);
  return &this->slot_ == &other_load->slot_;
}

Instruction* InitStaticFieldInstr::Canonicalize(FlowGraph* flow_graph) {
  const bool is_initialized =
      (field_.StaticValue() != Object::sentinel().raw()) &&
      (field_.StaticValue() != Object::transition_sentinel().raw());
  // When precompiling, the fact that a field is currently initialized does not
  // make it safe to omit code that checks if the field needs initialization
  // because the field will be reset so it starts uninitialized in the process
  // running the precompiled code. We must be prepared to reinitialize fields.
  return is_initialized && !FLAG_fields_may_be_reset ? NULL : this;
}

bool LoadStaticFieldInstr::AttributesEqual(Instruction* other) const {
  LoadStaticFieldInstr* other_load = other->AsLoadStaticField();
  ASSERT(other_load != NULL);
  // Assert that the field is initialized.
  ASSERT(StaticField().StaticValue() != Object::sentinel().raw());
  ASSERT(StaticField().StaticValue() != Object::transition_sentinel().raw());
  return StaticField().raw() == other_load->StaticField().raw();
}

const Field& LoadStaticFieldInstr::StaticField() const {
  return Field::Cast(field_value()->BoundConstant());
}

bool LoadStaticFieldInstr::IsFieldInitialized() const {
  const Field& field = StaticField();
  return (field.StaticValue() != Object::sentinel().raw()) &&
         (field.StaticValue() != Object::transition_sentinel().raw());
}

ConstantInstr::ConstantInstr(const Object& value, TokenPosition token_pos)
    : value_(value), token_pos_(token_pos) {
  // Check that the value is not an incorrect Integer representation.
  ASSERT(!value.IsMint() || !Smi::IsValid(Mint::Cast(value).AsInt64Value()));
  ASSERT(!value.IsField() || Field::Cast(value).IsOriginal());
  ASSERT(value.IsSmi() || value.IsOld());
}

bool ConstantInstr::AttributesEqual(Instruction* other) const {
  ConstantInstr* other_constant = other->AsConstant();
  ASSERT(other_constant != NULL);
  return (value().raw() == other_constant->value().raw());
}

UnboxedConstantInstr::UnboxedConstantInstr(const Object& value,
                                           Representation representation)
    : ConstantInstr(value),
      representation_(representation),
      constant_address_(0) {
  if (representation_ == kUnboxedDouble) {
    ASSERT(value.IsDouble());
    constant_address_ = FindDoubleConstant(Double::Cast(value).value());
  }
}

// Returns true if the value represents a constant.
bool Value::BindsToConstant() const {
  return definition()->IsConstant();
}

// Returns true if the value represents constant null.
bool Value::BindsToConstantNull() const {
  ConstantInstr* constant = definition()->AsConstant();
  return (constant != NULL) && constant->value().IsNull();
}

const Object& Value::BoundConstant() const {
  ASSERT(BindsToConstant());
  ConstantInstr* constant = definition()->AsConstant();
  ASSERT(constant != NULL);
  return constant->value();
}

GraphEntryInstr::GraphEntryInstr(const ParsedFunction& parsed_function,
                                 intptr_t osr_id)
    : BlockEntryWithInitialDefs(0,
                                kInvalidTryIndex,
                                CompilerState::Current().GetNextDeoptId()),
      parsed_function_(parsed_function),
      catch_entries_(),
      indirect_entries_(),
      osr_id_(osr_id),
      entry_count_(0),
      spill_slot_count_(0),
      fixed_slot_count_(0) {}

ConstantInstr* GraphEntryInstr::constant_null() {
  ASSERT(initial_definitions()->length() > 0);
  for (intptr_t i = 0; i < initial_definitions()->length(); ++i) {
    ConstantInstr* defn = (*initial_definitions())[i]->AsConstant();
    if (defn != NULL && defn->value().IsNull()) return defn;
  }
  UNREACHABLE();
  return NULL;
}

CatchBlockEntryInstr* GraphEntryInstr::GetCatchEntry(intptr_t index) {
  // TODO(fschneider): Sort the catch entries by catch_try_index to avoid
  // searching.
  for (intptr_t i = 0; i < catch_entries_.length(); ++i) {
    if (catch_entries_[i]->catch_try_index() == index) return catch_entries_[i];
  }
  return NULL;
}

bool GraphEntryInstr::IsCompiledForOsr() const {
  return osr_id_ != Compiler::kNoOSRDeoptId;
}

// ==== Support for visiting flow graphs.

#define DEFINE_ACCEPT(ShortName, Attrs)                                        \
  void ShortName##Instr::Accept(FlowGraphVisitor* visitor) {                   \
    visitor->Visit##ShortName(this);                                           \
  }

FOR_EACH_INSTRUCTION(DEFINE_ACCEPT)

#undef DEFINE_ACCEPT

void Instruction::SetEnvironment(Environment* deopt_env) {
  intptr_t use_index = 0;
  for (Environment::DeepIterator it(deopt_env); !it.Done(); it.Advance()) {
    Value* use = it.CurrentValue();
    use->set_instruction(this);
    use->set_use_index(use_index++);
  }
  env_ = deopt_env;
}

void Instruction::RemoveEnvironment() {
  for (Environment::DeepIterator it(env()); !it.Done(); it.Advance()) {
    it.CurrentValue()->RemoveFromUseList();
  }
  env_ = NULL;
}

void Instruction::ReplaceInEnvironment(Definition* current,
                                       Definition* replacement) {
  for (Environment::DeepIterator it(env()); !it.Done(); it.Advance()) {
    Value* use = it.CurrentValue();
    if (use->definition() == current) {
      use->RemoveFromUseList();
      use->set_definition(replacement);
      replacement->AddEnvUse(use);
    }
  }
}

Instruction* Instruction::RemoveFromGraph(bool return_previous) {
  ASSERT(!IsBlockEntry());
  ASSERT(!IsBranch());
  ASSERT(!IsThrow());
  ASSERT(!IsReturn());
  ASSERT(!IsReThrow());
  ASSERT(!IsGoto());
  ASSERT(previous() != NULL);
  // We cannot assert that the instruction, if it is a definition, has no
  // uses.  This function is used to remove instructions from the graph and
  // reinsert them elsewhere (e.g., hoisting).
  Instruction* prev_instr = previous();
  Instruction* next_instr = next();
  ASSERT(next_instr != NULL);
  ASSERT(!next_instr->IsBlockEntry());
  prev_instr->LinkTo(next_instr);
  UnuseAllInputs();
  // Reset the successor and previous instruction to indicate that the
  // instruction is removed from the graph.
  set_previous(NULL);
  set_next(NULL);
  return return_previous ? prev_instr : next_instr;
}

void Instruction::InsertAfter(Instruction* prev) {
  ASSERT(previous_ == NULL);
  ASSERT(next_ == NULL);
  previous_ = prev;
  next_ = prev->next_;
  next_->previous_ = this;
  previous_->next_ = this;

  // Update def-use chains whenever instructions are added to the graph
  // after initial graph construction.
  for (intptr_t i = InputCount() - 1; i >= 0; --i) {
    Value* input = InputAt(i);
    input->definition()->AddInputUse(input);
  }
}

Instruction* Instruction::AppendInstruction(Instruction* tail) {
  LinkTo(tail);
  // Update def-use chains whenever instructions are added to the graph
  // after initial graph construction.
  for (intptr_t i = tail->InputCount() - 1; i >= 0; --i) {
    Value* input = tail->InputAt(i);
    input->definition()->AddInputUse(input);
  }
  return tail;
}

BlockEntryInstr* Instruction::GetBlock() {
  // TODO(fschneider): Implement a faster way to get the block of an
  // instruction.
  Instruction* result = previous();
  ASSERT(result != nullptr);
  while (!result->IsBlockEntry()) {
    result = result->previous();
    ASSERT(result != nullptr);
  }
  return result->AsBlockEntry();
}

void ForwardInstructionIterator::RemoveCurrentFromGraph() {
  current_ = current_->RemoveFromGraph(true);  // Set current_ to previous.
}

void BackwardInstructionIterator::RemoveCurrentFromGraph() {
  current_ = current_->RemoveFromGraph(false);  // Set current_ to next.
}

// Default implementation of visiting basic blocks.  Can be overridden.
void FlowGraphVisitor::VisitBlocks() {
  ASSERT(current_iterator_ == NULL);
  for (intptr_t i = 0; i < block_order_.length(); ++i) {
    BlockEntryInstr* entry = block_order_[i];
    entry->Accept(this);
    ForwardInstructionIterator it(entry);
    current_iterator_ = &it;
    for (; !it.Done(); it.Advance()) {
      it.Current()->Accept(this);
    }
    current_iterator_ = NULL;
  }
}

bool Value::NeedsWriteBarrier() {
  if (Type()->IsNull() || (Type()->ToNullableCid() == kSmiCid) ||
      (Type()->ToNullableCid() == kBoolCid)) {
    return false;
  }

  // Strictly speaking, the incremental barrier can only be skipped for
  // immediate objects (Smis) or permanent objects (vm-isolate heap or
  // image pages). Here we choose to skip the barrier for any constant on
  // the assumption it will remain reachable through the object pool.

  return !BindsToConstant();
}

void JoinEntryInstr::AddPredecessor(BlockEntryInstr* predecessor) {
  // Require the predecessors to be sorted by block_id to make managing
  // their corresponding phi inputs simpler.
  intptr_t pred_id = predecessor->block_id();
  intptr_t index = 0;
  while ((index < predecessors_.length()) &&
         (predecessors_[index]->block_id() < pred_id)) {
    ++index;
  }
#if defined(DEBUG)
  for (intptr_t i = index; i < predecessors_.length(); ++i) {
    ASSERT(predecessors_[i]->block_id() != pred_id);
  }
#endif
  predecessors_.InsertAt(index, predecessor);
}

intptr_t JoinEntryInstr::IndexOfPredecessor(BlockEntryInstr* pred) const {
  for (intptr_t i = 0; i < predecessors_.length(); ++i) {
    if (predecessors_[i] == pred) return i;
  }
  return -1;
}

void Value::AddToList(Value* value, Value** list) {
  ASSERT(value->next_use() == nullptr);
  ASSERT(value->previous_use() == nullptr);
  Value* next = *list;
  ASSERT(value != next);
  *list = value;
  value->set_next_use(next);
  value->set_previous_use(NULL);
  if (next != NULL) next->set_previous_use(value);
}

void Value::RemoveFromUseList() {
  Definition* def = definition();
  Value* next = next_use();
  if (this == def->input_use_list()) {
    def->set_input_use_list(next);
    if (next != NULL) next->set_previous_use(NULL);
  } else if (this == def->env_use_list()) {
    def->set_env_use_list(next);
    if (next != NULL) next->set_previous_use(NULL);
  } else {
    Value* prev = previous_use();
    prev->set_next_use(next);
    if (next != NULL) next->set_previous_use(prev);
  }

  set_previous_use(NULL);
  set_next_use(NULL);
}

// True if the definition has a single input use and is used only in
// environments at the same instruction as that input use.
bool Definition::HasOnlyUse(Value* use) const {
  if (!HasOnlyInputUse(use)) {
    return false;
  }

  Instruction* target = use->instruction();
  for (Value::Iterator it(env_use_list()); !it.Done(); it.Advance()) {
    if (it.Current()->instruction() != target) return false;
  }
  return true;
}

bool Definition::HasOnlyInputUse(Value* use) const {
  return (input_use_list() == use) && (use->next_use() == NULL);
}

void Definition::ReplaceUsesWith(Definition* other) {
  ASSERT(other != NULL);
  ASSERT(this != other);

  Value* current = NULL;
  Value* next = input_use_list();
  if (next != NULL) {
    // Change all the definitions.
    while (next != NULL) {
      current = next;
      current->set_definition(other);
      current->RefineReachingType(other->Type());
      next = current->next_use();
    }

    // Concatenate the lists.
    next = other->input_use_list();
    current->set_next_use(next);
    if (next != NULL) next->set_previous_use(current);
    other->set_input_use_list(input_use_list());
    set_input_use_list(NULL);
  }

  // Repeat for environment uses.
  current = NULL;
  next = env_use_list();
  if (next != NULL) {
    while (next != NULL) {
      current = next;
      current->set_definition(other);
      current->RefineReachingType(other->Type());
      next = current->next_use();
    }
    next = other->env_use_list();
    current->set_next_use(next);
    if (next != NULL) next->set_previous_use(current);
    other->set_env_use_list(env_use_list());
    set_env_use_list(NULL);
  }
}

void Instruction::UnuseAllInputs() {
  for (intptr_t i = InputCount() - 1; i >= 0; --i) {
    InputAt(i)->RemoveFromUseList();
  }
  for (Environment::DeepIterator it(env()); !it.Done(); it.Advance()) {
    it.CurrentValue()->RemoveFromUseList();
  }
}

void Instruction::InheritDeoptTargetAfter(FlowGraph* flow_graph,
                                          Definition* call,
                                          Definition* result) {
  ASSERT(call->env() != NULL);
  deopt_id_ = DeoptId::ToDeoptAfter(call->deopt_id_);
  call->env()->DeepCopyAfterTo(
      flow_graph->zone(), this, call->ArgumentCount(),
      flow_graph->constant_dead(),
      result != NULL ? result : flow_graph->constant_dead());
}

void Instruction::InheritDeoptTarget(Zone* zone, Instruction* other) {
  ASSERT(other->env() != NULL);
  CopyDeoptIdFrom(*other);
  other->env()->DeepCopyTo(zone, this);
}

void BranchInstr::InheritDeoptTarget(Zone* zone, Instruction* other) {
  ASSERT(env() == NULL);
  Instruction::InheritDeoptTarget(zone, other);
  comparison()->SetDeoptId(*this);
}

bool Instruction::IsDominatedBy(Instruction* dom) {
  BlockEntryInstr* block = GetBlock();
  BlockEntryInstr* dom_block = dom->GetBlock();

  if (dom->IsPhi()) {
    dom = dom_block;
  }

  if (block == dom_block) {
    if ((block == dom) || (this == block->last_instruction())) {
      return true;
    }

    if (IsPhi()) {
      return false;
    }

    for (Instruction* curr = dom->next(); curr != NULL; curr = curr->next()) {
      if (curr == this) return true;
    }

    return false;
  }

  return dom_block->Dominates(block);
}

bool Instruction::HasUnmatchedInputRepresentations() const {
  for (intptr_t i = 0; i < InputCount(); i++) {
    Definition* input = InputAt(i)->definition();
    if (RequiredInputRepresentation(i) != input->representation()) {
      return true;
    }
  }

  return false;
}

const intptr_t Instruction::kInstructionAttrs[Instruction::kNumInstructions] = {
#define INSTR_ATTRS(type, attrs) InstrAttrs::attrs,
    FOR_EACH_INSTRUCTION(INSTR_ATTRS)
#undef INSTR_ATTRS
};

bool Instruction::CanTriggerGC() const {
  return (kInstructionAttrs[tag()] & InstrAttrs::kNoGC) == 0;
}

void Definition::ReplaceWithResult(Instruction* replacement,
                                   Definition* replacement_for_uses,
                                   ForwardInstructionIterator* iterator) {
  // Record replacement's input uses.
  for (intptr_t i = replacement->InputCount() - 1; i >= 0; --i) {
    Value* input = replacement->InputAt(i);
    input->definition()->AddInputUse(input);
  }
  // Take replacement's environment from this definition.
  ASSERT(replacement->env() == NULL);
  replacement->SetEnvironment(env());
  ClearEnv();
  // Replace all uses of this definition with replacement_for_uses.
  ReplaceUsesWith(replacement_for_uses);

  // Finally replace this one with the replacement instruction in the graph.
  previous()->LinkTo(replacement);
  if ((iterator != NULL) && (this == iterator->Current())) {
    // Remove through the iterator.
    replacement->LinkTo(this);
    iterator->RemoveCurrentFromGraph();
  } else {
    replacement->LinkTo(next());
    // Remove this definition's input uses.
    UnuseAllInputs();
  }
  set_previous(NULL);
  set_next(NULL);
}

void Definition::ReplaceWith(Definition* other,
                             ForwardInstructionIterator* iterator) {
  // Reuse this instruction's SSA name for other.
  ASSERT(!other->HasSSATemp());
  if (HasSSATemp()) {
    other->set_ssa_temp_index(ssa_temp_index());
  }
  ReplaceWithResult(other, other, iterator);
}

void BranchInstr::SetComparison(ComparisonInstr* new_comparison) {
  for (intptr_t i = new_comparison->InputCount() - 1; i >= 0; --i) {
    Value* input = new_comparison->InputAt(i);
    input->definition()->AddInputUse(input);
    input->set_instruction(this);
  }
  // There should be no need to copy or unuse an environment.
  ASSERT(comparison()->env() == NULL);
  ASSERT(new_comparison->env() == NULL);
  // Remove the current comparison's input uses.
  comparison()->UnuseAllInputs();
  ASSERT(!new_comparison->HasUses());
  comparison_ = new_comparison;
}

// ==== Postorder graph traversal.
static bool IsMarked(BlockEntryInstr* block,
                     GrowableArray<BlockEntryInstr*>* preorder) {
  // Detect that a block has been visited as part of the current
  // DiscoverBlocks (we can call DiscoverBlocks multiple times).  The block
  // will be 'marked' by (1) having a preorder number in the range of the
  // preorder array and (2) being in the preorder array at that index.
  intptr_t i = block->preorder_number();
  return (i >= 0) && (i < preorder->length()) && ((*preorder)[i] == block);
}

// Base class implementation used for JoinEntry and TargetEntry.
bool BlockEntryInstr::DiscoverBlock(BlockEntryInstr* predecessor,
                                    GrowableArray<BlockEntryInstr*>* preorder,
                                    GrowableArray<intptr_t>* parent) {
  // If this block has a predecessor (i.e., is not the graph entry) we can
  // assume the preorder array is non-empty.
  ASSERT((predecessor == NULL) || !preorder->is_empty());
  // Blocks with a single predecessor cannot have been reached before.
  ASSERT(IsJoinEntry() || !IsMarked(this, preorder));

  // 1. If the block has already been reached, add current_block as a
  // basic-block predecessor and we are done.
  if (IsMarked(this, preorder)) {
    ASSERT(predecessor != NULL);
    AddPredecessor(predecessor);
    return false;
  }

  // 2. Otherwise, clear the predecessors which might have been computed on
  // some earlier call to DiscoverBlocks and record this predecessor.
  ClearPredecessors();
  if (predecessor != NULL) AddPredecessor(predecessor);

  // 3. The predecessor is the spanning-tree parent.  The graph entry has no
  // parent, indicated by -1.
  intptr_t parent_number =
      (predecessor == NULL) ? -1 : predecessor->preorder_number();
  parent->Add(parent_number);

  // 4. Assign the preorder number and add the block entry to the list.
  set_preorder_number(preorder->length());
  preorder->Add(this);

  // The preorder and parent arrays are indexed by
  // preorder block number, so they should stay in lockstep.
  ASSERT(preorder->length() == parent->length());

  // 5. Iterate straight-line successors to record assigned variables and
  // find the last instruction in the block.  The graph entry block consists
  // of only the entry instruction, so that is the last instruction in the
  // block.
  Instruction* last = this;
  for (ForwardInstructionIterator it(this); !it.Done(); it.Advance()) {
    last = it.Current();
  }
  set_last_instruction(last);
  if (last->IsGoto()) last->AsGoto()->set_block(this);

  return true;
}

void GraphEntryInstr::RelinkToOsrEntry(Zone* zone, intptr_t max_block_id) {
  ASSERT(osr_id_ != Compiler::kNoOSRDeoptId);
  BitVector* block_marks = new (zone) BitVector(zone, max_block_id + 1);
  bool found = FindOsrEntryAndRelink(this, /*parent=*/NULL, block_marks);
  ASSERT(found);
}

bool BlockEntryInstr::FindOsrEntryAndRelink(GraphEntryInstr* graph_entry,
                                            Instruction* parent,
                                            BitVector* block_marks) {
  const intptr_t osr_id = graph_entry->osr_id();

  // Search for the instruction with the OSR id.  Use a depth first search
  // because basic blocks have not been discovered yet.  Prune unreachable
  // blocks by replacing the normal entry with a jump to the block
  // containing the OSR entry point.

  // Do not visit blocks more than once.
  if (block_marks->Contains(block_id())) return false;
  block_marks->Add(block_id());

  // Search this block for the OSR id.
  Instruction* instr = this;
  for (ForwardInstructionIterator it(this); !it.Done(); it.Advance()) {
    instr = it.Current();
    if (instr->GetDeoptId() == osr_id) {
      // Sanity check that we found a stack check instruction.
      ASSERT(instr->IsCheckStackOverflow());
      // Loop stack check checks are always in join blocks so that they can
      // be the target of a goto.
      ASSERT(IsJoinEntry());
      // The instruction should be the first instruction in the block so
      // we can simply jump to the beginning of the block.
      ASSERT(instr->previous() == this);

      const intptr_t stack_depth = instr->AsCheckStackOverflow()->stack_depth();
      auto normal_entry = graph_entry->normal_entry();
      auto osr_entry = new OsrEntryInstr(graph_entry, normal_entry->block_id(),
                                         normal_entry->try_index(),
                                         normal_entry->deopt_id(), stack_depth);

      auto goto_join = new GotoInstr(AsJoinEntry(),
                                     CompilerState::Current().GetNextDeoptId());
      goto_join->CopyDeoptIdFrom(*parent);
      osr_entry->LinkTo(goto_join);

      // Remove normal function entries & add osr entry.
      graph_entry->set_normal_entry(nullptr);
      graph_entry->set_unchecked_entry(nullptr);
      graph_entry->set_osr_entry(osr_entry);

      return true;
    }
  }

  // Recursively search the successors.
  for (intptr_t i = instr->SuccessorCount() - 1; i >= 0; --i) {
    if (instr->SuccessorAt(i)->FindOsrEntryAndRelink(graph_entry, instr,
                                                     block_marks)) {
      return true;
    }
  }
  return false;
}

bool BlockEntryInstr::Dominates(BlockEntryInstr* other) const {
  // TODO(fschneider): Make this faster by e.g. storing dominators for each
  // block while computing the dominator tree.
  ASSERT(other != NULL);
  BlockEntryInstr* current = other;
  while (current != NULL && current != this) {
    current = current->dominator();
  }
  return current == this;
}

BlockEntryInstr* BlockEntryInstr::ImmediateDominator() const {
  Instruction* last = dominator()->last_instruction();
  if ((last->SuccessorCount() == 1) && (last->SuccessorAt(0) == this)) {
    return dominator();
  }
  return NULL;
}

bool BlockEntryInstr::IsLoopHeader() const {
  return loop_info_ != nullptr && loop_info_->header() == this;
}

intptr_t BlockEntryInstr::NestingDepth() const {
  return loop_info_ == nullptr ? 0 : loop_info_->NestingDepth();
}

// Helper to mutate the graph during inlining. This block should be
// replaced with new_block as a predecessor of all of this block's
// successors.  For each successor, the predecessors will be reordered
// to preserve block-order sorting of the predecessors as well as the
// phis if the successor is a join.
void BlockEntryInstr::ReplaceAsPredecessorWith(BlockEntryInstr* new_block) {
  // Set the last instruction of the new block to that of the old block.
  Instruction* last = last_instruction();
  new_block->set_last_instruction(last);
  // For each successor, update the predecessors.
  for (intptr_t sidx = 0; sidx < last->SuccessorCount(); ++sidx) {
    // If the successor is a target, update its predecessor.
    TargetEntryInstr* target = last->SuccessorAt(sidx)->AsTargetEntry();
    if (target != NULL) {
      target->predecessor_ = new_block;
      continue;
    }
    // If the successor is a join, update each predecessor and the phis.
    JoinEntryInstr* join = last->SuccessorAt(sidx)->AsJoinEntry();
    ASSERT(join != NULL);
    // Find the old predecessor index.
    intptr_t old_index = join->IndexOfPredecessor(this);
    intptr_t pred_count = join->PredecessorCount();
    ASSERT(old_index >= 0);
    ASSERT(old_index < pred_count);
    // Find the new predecessor index while reordering the predecessors.
    intptr_t new_id = new_block->block_id();
    intptr_t new_index = old_index;
    if (block_id() < new_id) {
      // Search upwards, bubbling down intermediate predecessors.
      for (; new_index < pred_count - 1; ++new_index) {
        if (join->predecessors_[new_index + 1]->block_id() > new_id) break;
        join->predecessors_[new_index] = join->predecessors_[new_index + 1];
      }
    } else {
      // Search downwards, bubbling up intermediate predecessors.
      for (; new_index > 0; --new_index) {
        if (join->predecessors_[new_index - 1]->block_id() < new_id) break;
        join->predecessors_[new_index] = join->predecessors_[new_index - 1];
      }
    }
    join->predecessors_[new_index] = new_block;
    // If the new and old predecessor index match there is nothing to update.
    if ((join->phis() == NULL) || (old_index == new_index)) return;
    // Otherwise, reorder the predecessor uses in each phi.
    for (PhiIterator it(join); !it.Done(); it.Advance()) {
      PhiInstr* phi = it.Current();
      ASSERT(phi != NULL);
      ASSERT(pred_count == phi->InputCount());
      // Save the predecessor use.
      Value* pred_use = phi->InputAt(old_index);
      // Move uses between old and new.
      intptr_t step = (old_index < new_index) ? 1 : -1;
      for (intptr_t use_idx = old_index; use_idx != new_index;
           use_idx += step) {
        phi->SetInputAt(use_idx, phi->InputAt(use_idx + step));
      }
      // Write the predecessor use.
      phi->SetInputAt(new_index, pred_use);
    }
  }
}

void BlockEntryInstr::ClearAllInstructions() {
  JoinEntryInstr* join = this->AsJoinEntry();
  if (join != NULL) {
    for (PhiIterator it(join); !it.Done(); it.Advance()) {
      it.Current()->UnuseAllInputs();
    }
  }
  UnuseAllInputs();
  for (ForwardInstructionIterator it(this); !it.Done(); it.Advance()) {
    it.Current()->UnuseAllInputs();
  }
}

PhiInstr* JoinEntryInstr::InsertPhi(intptr_t var_index, intptr_t var_count) {
  // Lazily initialize the array of phis.
  // Currently, phis are stored in a sparse array that holds the phi
  // for variable with index i at position i.
  // TODO(fschneider): Store phis in a more compact way.
  if (phis_ == NULL) {
    phis_ = new ZoneGrowableArray<PhiInstr*>(var_count);
    for (intptr_t i = 0; i < var_count; i++) {
      phis_->Add(NULL);
    }
  }
  ASSERT((*phis_)[var_index] == NULL);
  return (*phis_)[var_index] = new PhiInstr(this, PredecessorCount());
}

void JoinEntryInstr::InsertPhi(PhiInstr* phi) {
  // Lazily initialize the array of phis.
  if (phis_ == NULL) {
    phis_ = new ZoneGrowableArray<PhiInstr*>(1);
  }
  phis_->Add(phi);
}

void JoinEntryInstr::RemovePhi(PhiInstr* phi) {
  ASSERT(phis_ != NULL);
  for (intptr_t index = 0; index < phis_->length(); ++index) {
    if (phi == (*phis_)[index]) {
      (*phis_)[index] = phis_->Last();
      phis_->RemoveLast();
      return;
    }
  }
}

void JoinEntryInstr::RemoveDeadPhis(Definition* replacement) {
  if (phis_ == NULL) return;

  intptr_t to_index = 0;
  for (intptr_t from_index = 0; from_index < phis_->length(); ++from_index) {
    PhiInstr* phi = (*phis_)[from_index];
    if (phi != NULL) {
      if (phi->is_alive()) {
        (*phis_)[to_index++] = phi;
        for (intptr_t i = phi->InputCount() - 1; i >= 0; --i) {
          Value* input = phi->InputAt(i);
          input->definition()->AddInputUse(input);
        }
      } else {
        phi->ReplaceUsesWith(replacement);
      }
    }
  }
  if (to_index == 0) {
    phis_ = NULL;
  } else {
    phis_->TruncateTo(to_index);
  }
}

intptr_t Instruction::SuccessorCount() const {
  return 0;
}

BlockEntryInstr* Instruction::SuccessorAt(intptr_t index) const {
  // Called only if index is in range.  Only control-transfer instructions
  // can have non-zero successor counts and they override this function.
  UNREACHABLE();
  return NULL;
}

intptr_t GraphEntryInstr::SuccessorCount() const {
  return (normal_entry() == nullptr ? 0 : 1) +
         (unchecked_entry() == nullptr ? 0 : 1) +
         (osr_entry() == nullptr ? 0 : 1) + catch_entries_.length();
}

BlockEntryInstr* GraphEntryInstr::SuccessorAt(intptr_t index) const {
  if (normal_entry() != nullptr) {
    if (index == 0) return normal_entry_;
    index--;
  }
  if (unchecked_entry() != nullptr) {
    if (index == 0) return unchecked_entry();
    index--;
  }
  if (osr_entry() != nullptr) {
    if (index == 0) return osr_entry();
    index--;
  }
  return catch_entries_[index];
}

intptr_t BranchInstr::SuccessorCount() const {
  return 2;
}

BlockEntryInstr* BranchInstr::SuccessorAt(intptr_t index) const {
  if (index == 0) return true_successor_;
  if (index == 1) return false_successor_;
  UNREACHABLE();
  return NULL;
}

intptr_t GotoInstr::SuccessorCount() const {
  return 1;
}

BlockEntryInstr* GotoInstr::SuccessorAt(intptr_t index) const {
  ASSERT(index == 0);
  return successor();
}

void Instruction::Goto(JoinEntryInstr* entry) {
  LinkTo(new GotoInstr(entry, CompilerState::Current().GetNextDeoptId()));
}

bool IntConverterInstr::ComputeCanDeoptimize() const {
  return (to() == kUnboxedInt32) && !is_truncating() &&
         !RangeUtils::Fits(value()->definition()->range(),
                           RangeBoundary::kRangeBoundaryInt32);
}

bool UnboxInt32Instr::ComputeCanDeoptimize() const {
  if (speculative_mode() == kNotSpeculative) {
    return false;
  }
  const intptr_t value_cid = value()->Type()->ToCid();
  if (value_cid == kSmiCid) {
    return (compiler::target::kSmiBits > 32) && !is_truncating() &&
           !RangeUtils::Fits(value()->definition()->range(),
                             RangeBoundary::kRangeBoundaryInt32);
  } else if (value_cid == kMintCid) {
    return !is_truncating() &&
           !RangeUtils::Fits(value()->definition()->range(),
                             RangeBoundary::kRangeBoundaryInt32);
  } else if (is_truncating() && value()->definition()->IsBoxInteger()) {
    return false;
  } else if ((compiler::target::kSmiBits < 32) && value()->Type()->IsInt()) {
    return !RangeUtils::Fits(value()->definition()->range(),
                             RangeBoundary::kRangeBoundaryInt32);
  } else {
    return true;
  }
}

bool UnboxUint32Instr::ComputeCanDeoptimize() const {
  ASSERT(is_truncating());
  if (speculative_mode() == kNotSpeculative) {
    return false;
  }
  if ((value()->Type()->ToCid() == kSmiCid) ||
      (value()->Type()->ToCid() == kMintCid)) {
    return false;
  }
  // Check input value's range.
  Range* value_range = value()->definition()->range();
  return !RangeUtils::Fits(value_range, RangeBoundary::kRangeBoundaryInt64);
}

bool BinaryInt32OpInstr::ComputeCanDeoptimize() const {
  switch (op_kind()) {
    case Token::kBIT_AND:
    case Token::kBIT_OR:
    case Token::kBIT_XOR:
      return false;

    case Token::kSHR:
      return false;

    case Token::kSHL:
      // Currently only shifts by in range constant are supported, see
      // BinaryInt32OpInstr::IsSupported.
      return can_overflow();

    case Token::kMOD: {
      UNREACHABLE();
    }

    default:
      return can_overflow();
  }
}

bool BinarySmiOpInstr::ComputeCanDeoptimize() const {
  switch (op_kind()) {
    case Token::kBIT_AND:
    case Token::kBIT_OR:
    case Token::kBIT_XOR:
      return false;

    case Token::kSHR:
      return !RangeUtils::IsPositive(right_range());

    case Token::kSHL:
      return can_overflow() || !RangeUtils::IsPositive(right_range());

    case Token::kMOD:
      return RangeUtils::CanBeZero(right_range());

    case Token::kTRUNCDIV:
#if defined(TARGET_ARCH_DBC)
      return true;
#else
      return RangeUtils::CanBeZero(right_range()) ||
             RangeUtils::Overlaps(right_range(), -1, -1);
#endif

    default:
      return can_overflow();
  }
}

bool ShiftIntegerOpInstr::IsShiftCountInRange(int64_t max) const {
  return RangeUtils::IsWithin(shift_range(), 0, max);
}

bool BinaryIntegerOpInstr::RightIsPowerOfTwoConstant() const {
  if (!right()->definition()->IsConstant()) return false;
  const Object& constant = right()->definition()->AsConstant()->value();
  if (!constant.IsSmi()) return false;
  const intptr_t int_value = Smi::Cast(constant).Value();
  ASSERT(int_value != kIntptrMin);
  return Utils::IsPowerOfTwo(Utils::Abs(int_value));
}

static intptr_t RepresentationBits(Representation r) {
  switch (r) {
    case kTagged:
      return compiler::target::kBitsPerWord - 1;
    case kUnboxedInt32:
    case kUnboxedUint32:
      return 32;
    case kUnboxedInt64:
      return 64;
    default:
      UNREACHABLE();
      return 0;
  }
}

static int64_t RepresentationMask(Representation r) {
  return static_cast<int64_t>(static_cast<uint64_t>(-1) >>
                              (64 - RepresentationBits(r)));
}

static bool ToIntegerConstant(Value* value, int64_t* result) {
  if (!value->BindsToConstant()) {
    UnboxInstr* unbox = value->definition()->AsUnbox();
    if (unbox != NULL) {
      switch (unbox->representation()) {
        case kUnboxedDouble:
        case kUnboxedInt64:
          return ToIntegerConstant(unbox->value(), result);

        case kUnboxedUint32:
          if (ToIntegerConstant(unbox->value(), result)) {
            *result &= RepresentationMask(kUnboxedUint32);
            return true;
          }
          break;

        // No need to handle Unbox<Int32>(Constant(C)) because it gets
        // canonicalized to UnboxedConstant<Int32>(C).
        case kUnboxedInt32:
        default:
          break;
      }
    }
    return false;
  }

  const Object& constant = value->BoundConstant();
  if (constant.IsDouble()) {
    const Double& double_constant = Double::Cast(constant);
    *result = Utils::SafeDoubleToInt<int64_t>(double_constant.value());
    return (static_cast<double>(*result) == double_constant.value());
  } else if (constant.IsSmi()) {
    *result = Smi::Cast(constant).Value();
    return true;
  } else if (constant.IsMint()) {
    *result = Mint::Cast(constant).value();
    return true;
  }

  return false;
}

static Definition* CanonicalizeCommutativeDoubleArithmetic(Token::Kind op,
                                                           Value* left,
                                                           Value* right) {
  int64_t left_value;
  if (!ToIntegerConstant(left, &left_value)) {
    return NULL;
  }

  // Can't apply 0.0 * x -> 0.0 equivalence to double operation because
  // 0.0 * NaN is NaN not 0.0.
  // Can't apply 0.0 + x -> x to double because 0.0 + (-0.0) is 0.0 not -0.0.
  switch (op) {
    case Token::kMUL:
      if (left_value == 1) {
        if (right->definition()->representation() != kUnboxedDouble) {
          // Can't yet apply the equivalence because representation selection
          // did not run yet. We need it to guarantee that right value is
          // correctly coerced to double. The second canonicalization pass
          // will apply this equivalence.
          return NULL;
        } else {
          return right->definition();
        }
      }
      break;
    default:
      break;
  }

  return NULL;
}

Definition* DoubleToFloatInstr::Canonicalize(FlowGraph* flow_graph) {
#ifdef DEBUG
  // Must only be used in Float32 StoreIndexedInstr or FloatToDoubleInstr or
  // Phis introduce by load forwarding.
  ASSERT(env_use_list() == NULL);
  for (Value* use = input_use_list(); use != NULL; use = use->next_use()) {
    ASSERT(use->instruction()->IsPhi() ||
           use->instruction()->IsFloatToDouble() ||
           (use->instruction()->IsStoreIndexed() &&
            (use->instruction()->AsStoreIndexed()->class_id() ==
             kTypedDataFloat32ArrayCid)));
  }
#endif
  if (!HasUses()) return NULL;
  if (value()->definition()->IsFloatToDouble()) {
    // F2D(D2F(v)) == v.
    return value()->definition()->AsFloatToDouble()->value()->definition();
  }
  return this;
}

Definition* FloatToDoubleInstr::Canonicalize(FlowGraph* flow_graph) {
  return HasUses() ? this : NULL;
}

Definition* BinaryDoubleOpInstr::Canonicalize(FlowGraph* flow_graph) {
  if (!HasUses()) return NULL;

  Definition* result = NULL;

  result = CanonicalizeCommutativeDoubleArithmetic(op_kind(), left(), right());
  if (result != NULL) {
    return result;
  }

  result = CanonicalizeCommutativeDoubleArithmetic(op_kind(), right(), left());
  if (result != NULL) {
    return result;
  }

  if ((op_kind() == Token::kMUL) &&
      (left()->definition() == right()->definition())) {
    MathUnaryInstr* math_unary = new MathUnaryInstr(
        MathUnaryInstr::kDoubleSquare, new Value(left()->definition()),
        DeoptimizationTarget());
    flow_graph->InsertBefore(this, math_unary, env(), FlowGraph::kValue);
    return math_unary;
  }

  return this;
}

Definition* DoubleTestOpInstr::Canonicalize(FlowGraph* flow_graph) {
  return HasUses() ? this : NULL;
}

static bool IsCommutative(Token::Kind op) {
  switch (op) {
    case Token::kMUL:
      FALL_THROUGH;
    case Token::kADD:
      FALL_THROUGH;
    case Token::kBIT_AND:
      FALL_THROUGH;
    case Token::kBIT_OR:
      FALL_THROUGH;
    case Token::kBIT_XOR:
      return true;
    default:
      return false;
  }
}

UnaryIntegerOpInstr* UnaryIntegerOpInstr::Make(Representation representation,
                                               Token::Kind op_kind,
                                               Value* value,
                                               intptr_t deopt_id,
                                               Range* range) {
  UnaryIntegerOpInstr* op = NULL;
  switch (representation) {
    case kTagged:
      op = new UnarySmiOpInstr(op_kind, value, deopt_id);
      break;
    case kUnboxedInt32:
      return NULL;
    case kUnboxedUint32:
      op = new UnaryUint32OpInstr(op_kind, value, deopt_id);
      break;
    case kUnboxedInt64:
      op = new UnaryInt64OpInstr(op_kind, value, deopt_id);
      break;
    default:
      UNREACHABLE();
      return NULL;
  }

  if (op == NULL) {
    return op;
  }

  if (!Range::IsUnknown(range)) {
    op->set_range(*range);
  }

  ASSERT(op->representation() == representation);
  return op;
}

BinaryIntegerOpInstr* BinaryIntegerOpInstr::Make(
    Representation representation,
    Token::Kind op_kind,
    Value* left,
    Value* right,
    intptr_t deopt_id,
    bool can_overflow,
    bool is_truncating,
    Range* range,
    SpeculativeMode speculative_mode) {
  BinaryIntegerOpInstr* op = NULL;
  switch (representation) {
    case kTagged:
      op = new BinarySmiOpInstr(op_kind, left, right, deopt_id);
      break;
    case kUnboxedInt32:
      if (!BinaryInt32OpInstr::IsSupported(op_kind, left, right)) {
        return NULL;
      }
      op = new BinaryInt32OpInstr(op_kind, left, right, deopt_id);
      break;
    case kUnboxedUint32:
      if ((op_kind == Token::kSHR) || (op_kind == Token::kSHL)) {
        if (speculative_mode == kNotSpeculative) {
          op = new ShiftUint32OpInstr(op_kind, left, right, deopt_id);
        } else {
          op =
              new SpeculativeShiftUint32OpInstr(op_kind, left, right, deopt_id);
        }
      } else {
        op = new BinaryUint32OpInstr(op_kind, left, right, deopt_id);
      }
      break;
    case kUnboxedInt64:
      if ((op_kind == Token::kSHR) || (op_kind == Token::kSHL)) {
        if (speculative_mode == kNotSpeculative) {
          op = new ShiftInt64OpInstr(op_kind, left, right, deopt_id);
        } else {
          op = new SpeculativeShiftInt64OpInstr(op_kind, left, right, deopt_id);
        }
      } else {
        op = new BinaryInt64OpInstr(op_kind, left, right, deopt_id);
      }
      break;
    default:
      UNREACHABLE();
      return NULL;
  }

  if (!Range::IsUnknown(range)) {
    op->set_range(*range);
  }

  op->set_can_overflow(can_overflow);
  if (is_truncating) {
    op->mark_truncating();
  }

  ASSERT(op->representation() == representation);
  return op;
}

static bool IsRepresentable(const Integer& value, Representation rep) {
  switch (rep) {
    case kTagged:  // Smi case.
      return value.IsSmi();

    case kUnboxedInt32:
      if (value.IsSmi() || value.IsMint()) {
        return Utils::IsInt(32, value.AsInt64Value());
      }
      return false;

    case kUnboxedInt64:
      return value.IsSmi() || value.IsMint();

    case kUnboxedUint32:
      if (value.IsSmi() || value.IsMint()) {
        return Utils::IsUint(32, value.AsInt64Value());
      }
      return false;

    default:
      UNREACHABLE();
  }

  return false;
}

RawInteger* UnaryIntegerOpInstr::Evaluate(const Integer& value) const {
  Thread* thread = Thread::Current();
  Zone* zone = thread->zone();
  Integer& result = Integer::Handle(zone);

  switch (op_kind()) {
    case Token::kNEGATE:
      result = value.ArithmeticOp(Token::kMUL, Smi::Handle(zone, Smi::New(-1)),
                                  Heap::kOld);
      break;

    case Token::kBIT_NOT:
      if (value.IsSmi()) {
        result = Integer::New(~Smi::Cast(value).Value(), Heap::kOld);
      } else if (value.IsMint()) {
        result = Integer::New(~Mint::Cast(value).value(), Heap::kOld);
      }
      break;

    default:
      UNREACHABLE();
  }

  if (!result.IsNull()) {
    if (!IsRepresentable(result, representation())) {
      // If this operation is not truncating it would deoptimize on overflow.
      // Check that we match this behavior and don't produce a value that is
      // larger than something this operation can produce. We could have
      // specialized instructions that use this value under this assumption.
      return Integer::null();
    }

    const char* error_str = NULL;
    result ^= result.CheckAndCanonicalize(thread, &error_str);
    if (error_str != NULL) {
      FATAL1("Failed to canonicalize: %s", error_str);
    }
  }

  return result.raw();
}

RawInteger* BinaryIntegerOpInstr::Evaluate(const Integer& left,
                                           const Integer& right) const {
  Thread* thread = Thread::Current();
  Zone* zone = thread->zone();
  Integer& result = Integer::Handle(zone);

  switch (op_kind()) {
    case Token::kTRUNCDIV:
      FALL_THROUGH;
    case Token::kMOD:
      // Check right value for zero.
      if (right.AsInt64Value() == 0) {
        break;  // Will throw.
      }
      FALL_THROUGH;
    case Token::kADD:
      FALL_THROUGH;
    case Token::kSUB:
      FALL_THROUGH;
    case Token::kMUL: {
      result = left.ArithmeticOp(op_kind(), right, Heap::kOld);
      break;
    }
    case Token::kSHL:
      FALL_THROUGH;
    case Token::kSHR:
      if (right.AsInt64Value() >= 0) {
        result = left.ShiftOp(op_kind(), right, Heap::kOld);
      }
      break;
    case Token::kBIT_AND:
      FALL_THROUGH;
    case Token::kBIT_OR:
      FALL_THROUGH;
    case Token::kBIT_XOR: {
      result = left.BitOp(op_kind(), right, Heap::kOld);
      break;
    }
    case Token::kDIV:
      break;
    default:
      UNREACHABLE();
  }

  if (!result.IsNull()) {
    if (is_truncating()) {
      int64_t truncated = result.AsTruncatedInt64Value();
      truncated &= RepresentationMask(representation());
      result = Integer::New(truncated, Heap::kOld);
      ASSERT(IsRepresentable(result, representation()));
    } else if (!IsRepresentable(result, representation())) {
      // If this operation is not truncating it would deoptimize on overflow.
      // Check that we match this behavior and don't produce a value that is
      // larger than something this operation can produce. We could have
      // specialized instructions that use this value under this assumption.
      return Integer::null();
    }
    const char* error_str = NULL;
    result ^= result.CheckAndCanonicalize(thread, &error_str);
    if (error_str != NULL) {
      FATAL1("Failed to canonicalize: %s", error_str);
    }
  }

  return result.raw();
}

Definition* BinaryIntegerOpInstr::CreateConstantResult(FlowGraph* flow_graph,
                                                       const Integer& result) {
  Definition* result_defn = flow_graph->GetConstant(result);
  if (representation() != kTagged) {
    result_defn = UnboxInstr::Create(representation(), new Value(result_defn),
                                     GetDeoptId());
    flow_graph->InsertBefore(this, result_defn, env(), FlowGraph::kValue);
  }
  return result_defn;
}

Definition* CheckedSmiOpInstr::Canonicalize(FlowGraph* flow_graph) {
  if ((left()->Type()->ToCid() == kSmiCid) &&
      (right()->Type()->ToCid() == kSmiCid)) {
    Definition* replacement = NULL;
    // Operations that can't deoptimize are specialized here: These include
    // bit-wise operators and comparisons. Other arithmetic operations can
    // overflow or divide by 0 and can't be specialized unless we have extra
    // range information.
    switch (op_kind()) {
      case Token::kBIT_AND:
        FALL_THROUGH;
      case Token::kBIT_OR:
        FALL_THROUGH;
      case Token::kBIT_XOR:
        replacement = new BinarySmiOpInstr(
            op_kind(), new Value(left()->definition()),
            new Value(right()->definition()), DeoptId::kNone);
        FALL_THROUGH;
      default:
        break;
    }
    if (replacement != NULL) {
      flow_graph->InsertBefore(this, replacement, env(), FlowGraph::kValue);
      return replacement;
    }
  }
  return this;
}

ComparisonInstr* CheckedSmiComparisonInstr::CopyWithNewOperands(Value* left,
                                                                Value* right) {
  UNREACHABLE();
  return NULL;
}

Definition* CheckedSmiComparisonInstr::Canonicalize(FlowGraph* flow_graph) {
  CompileType* left_type = left()->Type();
  CompileType* right_type = right()->Type();
  intptr_t op_cid = kIllegalCid;
  SpeculativeMode speculative_mode = kGuardInputs;

  if ((left_type->ToCid() == kSmiCid) && (right_type->ToCid() == kSmiCid)) {
    op_cid = kSmiCid;
  } else if (Isolate::Current()->can_use_strong_mode_types() &&
             FlowGraphCompiler::SupportsUnboxedInt64() &&
             // TODO(dartbug.com/30480): handle nullable types here
             left_type->IsNullableInt() && !left_type->is_nullable() &&
             right_type->IsNullableInt() && !right_type->is_nullable()) {
    op_cid = kMintCid;
    speculative_mode = kNotSpeculative;
  }

  if (op_cid != kIllegalCid) {
    Definition* replacement = NULL;
    if (Token::IsRelationalOperator(kind())) {
      replacement = new RelationalOpInstr(
          token_pos(), kind(), left()->CopyWithType(), right()->CopyWithType(),
          op_cid, DeoptId::kNone, speculative_mode);
    } else if (Token::IsEqualityOperator(kind())) {
      replacement = new EqualityCompareInstr(
          token_pos(), kind(), left()->CopyWithType(), right()->CopyWithType(),
          op_cid, DeoptId::kNone, speculative_mode);
    }
    if (replacement != NULL) {
      if (FLAG_trace_strong_mode_types && (op_cid == kMintCid)) {
        THR_Print("[Strong mode] Optimization: replacing %s with %s\n",
                  ToCString(), replacement->ToCString());
      }
      flow_graph->InsertBefore(this, replacement, env(), FlowGraph::kValue);
      return replacement;
    }
  }
  return this;
}

Definition* BinaryIntegerOpInstr::Canonicalize(FlowGraph* flow_graph) {
  // If both operands are constants evaluate this expression. Might
  // occur due to load forwarding after constant propagation pass
  // have already been run.
  if (left()->BindsToConstant() && left()->BoundConstant().IsInteger() &&
      right()->BindsToConstant() && right()->BoundConstant().IsInteger()) {
    const Integer& result =
        Integer::Handle(Evaluate(Integer::Cast(left()->BoundConstant()),
                                 Integer::Cast(right()->BoundConstant())));
    if (!result.IsNull()) {
      return CreateConstantResult(flow_graph, result);
    }
  }

  if (left()->BindsToConstant() && !right()->BindsToConstant() &&
      IsCommutative(op_kind())) {
    Value* l = left();
    Value* r = right();
    SetInputAt(0, r);
    SetInputAt(1, l);
  }

  int64_t rhs;
  if (!ToIntegerConstant(right(), &rhs)) {
    return this;
  }

  const int64_t range_mask = RepresentationMask(representation());
  if (is_truncating()) {
    switch (op_kind()) {
      case Token::kMUL:
      case Token::kSUB:
      case Token::kADD:
      case Token::kBIT_AND:
      case Token::kBIT_OR:
      case Token::kBIT_XOR:
        rhs = (rhs & range_mask);
        break;
      default:
        break;
    }
  }

  switch (op_kind()) {
    case Token::kMUL:
      if (rhs == 1) {
        return left()->definition();
      } else if (rhs == 0) {
        return right()->definition();
      } else if (rhs == 2) {
        const int64_t shift_1 = 1;
        ConstantInstr* constant_1 =
            flow_graph->GetConstant(Smi::Handle(Smi::New(shift_1)));
        BinaryIntegerOpInstr* shift = BinaryIntegerOpInstr::Make(
            representation(), Token::kSHL, left()->CopyWithType(),
            new Value(constant_1), GetDeoptId(), can_overflow(),
            is_truncating(), range(), speculative_mode());
        if (shift != nullptr) {
          // Assign a range to the shift factor, just in case range
          // analysis no longer runs after this rewriting.
          if (auto shift_with_range = shift->AsShiftIntegerOp()) {
            shift_with_range->set_shift_range(
                new Range(RangeBoundary::FromConstant(shift_1),
                          RangeBoundary::FromConstant(shift_1)));
          }
          flow_graph->InsertBefore(this, shift, env(), FlowGraph::kValue);
          return shift;
        }
      }

      break;
    case Token::kADD:
      if (rhs == 0) {
        return left()->definition();
      }
      break;
    case Token::kBIT_AND:
      if (rhs == 0) {
        return right()->definition();
      } else if (rhs == range_mask) {
        return left()->definition();
      }
      break;
    case Token::kBIT_OR:
      if (rhs == 0) {
        return left()->definition();
      } else if (rhs == range_mask) {
        return right()->definition();
      }
      break;
    case Token::kBIT_XOR:
      if (rhs == 0) {
        return left()->definition();
      } else if (rhs == range_mask) {
        UnaryIntegerOpInstr* bit_not = UnaryIntegerOpInstr::Make(
            representation(), Token::kBIT_NOT, left()->CopyWithType(),
            GetDeoptId(), range());
        if (bit_not != NULL) {
          flow_graph->InsertBefore(this, bit_not, env(), FlowGraph::kValue);
          return bit_not;
        }
      }
      break;

    case Token::kSUB:
      if (rhs == 0) {
        return left()->definition();
      }
      break;

    case Token::kTRUNCDIV:
      if (rhs == 1) {
        return left()->definition();
      } else if (rhs == -1) {
        UnaryIntegerOpInstr* negation = UnaryIntegerOpInstr::Make(
            representation(), Token::kNEGATE, left()->CopyWithType(),
            GetDeoptId(), range());
        if (negation != NULL) {
          flow_graph->InsertBefore(this, negation, env(), FlowGraph::kValue);
          return negation;
        }
      }
      break;

    case Token::kSHR:
      if (rhs == 0) {
        return left()->definition();
      } else if (rhs < 0) {
        // Instruction will always throw on negative rhs operand.
        if (!CanDeoptimize()) {
          // For non-speculative operations (no deopt), let
          // the code generator deal with throw on slowpath.
          break;
        }
        ASSERT(GetDeoptId() != DeoptId::kNone);
        DeoptimizeInstr* deopt =
            new DeoptimizeInstr(ICData::kDeoptBinarySmiOp, GetDeoptId());
        flow_graph->InsertBefore(this, deopt, env(), FlowGraph::kEffect);
        // Replace with zero since it always throws.
        return CreateConstantResult(flow_graph, Integer::Handle(Smi::New(0)));
      }
      break;

    case Token::kSHL: {
      const intptr_t result_bits = RepresentationBits(representation());
      if (rhs == 0) {
        return left()->definition();
      } else if ((rhs >= kBitsPerInt64) ||
                 ((rhs >= result_bits) && is_truncating())) {
        return CreateConstantResult(flow_graph, Integer::Handle(Smi::New(0)));
      } else if ((rhs < 0) || ((rhs >= result_bits) && !is_truncating())) {
        // Instruction will always throw on negative rhs operand or
        // deoptimize on large rhs operand.
        if (!CanDeoptimize()) {
          // For non-speculative operations (no deopt), let
          // the code generator deal with throw on slowpath.
          break;
        }
        ASSERT(GetDeoptId() != DeoptId::kNone);
        DeoptimizeInstr* deopt =
            new DeoptimizeInstr(ICData::kDeoptBinarySmiOp, GetDeoptId());
        flow_graph->InsertBefore(this, deopt, env(), FlowGraph::kEffect);
        // Replace with zero since it overshifted or always throws.
        return CreateConstantResult(flow_graph, Integer::Handle(Smi::New(0)));
      }
      break;
    }

    default:
      break;
  }

  return this;
}

// Optimizations that eliminate or simplify individual instructions.
Instruction* Instruction::Canonicalize(FlowGraph* flow_graph) {
  return this;
}

Definition* Definition::Canonicalize(FlowGraph* flow_graph) {
  return this;
}

Definition* RedefinitionInstr::Canonicalize(FlowGraph* flow_graph) {
  // Must not remove Redifinitions without uses until LICM, even though
  // Redefinition might not have any uses itself it can still be dominating
  // uses of the value it redefines and must serve as a barrier for those
  // uses. RenameUsesDominatedByRedefinitions would normalize the graph and
  // route those uses through this redefinition.
  if (!HasUses() && !flow_graph->is_licm_allowed()) {
    return NULL;
  }
  if ((constrained_type() != nullptr) && Type()->IsEqualTo(value()->Type())) {
    return value()->definition();
  }
  return this;
}

Instruction* CheckStackOverflowInstr::Canonicalize(FlowGraph* flow_graph) {
  switch (kind_) {
    case kOsrAndPreemption:
      return this;
    case kOsrOnly:
      // Don't need OSR entries in the optimized code.
      return NULL;
  }

  // Switch above exhausts all possibilities but some compilers can't figure
  // it out.
  UNREACHABLE();
  return this;
}

bool LoadFieldInstr::IsImmutableLengthLoad() const {
  switch (slot().kind()) {
    case Slot::Kind::kArray_length:
    case Slot::Kind::kTypedDataBase_length:
    case Slot::Kind::kString_length:
      return true;
    case Slot::Kind::kGrowableObjectArray_length:
      return false;

    // Not length loads.
    case Slot::Kind::kLinkedHashMap_index:
    case Slot::Kind::kLinkedHashMap_data:
    case Slot::Kind::kLinkedHashMap_hash_mask:
    case Slot::Kind::kLinkedHashMap_used_data:
    case Slot::Kind::kLinkedHashMap_deleted_keys:
    case Slot::Kind::kArgumentsDescriptor_type_args_len:
    case Slot::Kind::kArgumentsDescriptor_positional_count:
    case Slot::Kind::kArgumentsDescriptor_count:
    case Slot::Kind::kTypeArguments:
    case Slot::Kind::kTypedDataBase_data_field:
    case Slot::Kind::kTypedDataView_offset_in_bytes:
    case Slot::Kind::kTypedDataView_data:
    case Slot::Kind::kGrowableObjectArray_data:
    case Slot::Kind::kContext_parent:
    case Slot::Kind::kClosure_context:
    case Slot::Kind::kClosure_delayed_type_arguments:
    case Slot::Kind::kClosure_function:
    case Slot::Kind::kClosure_function_type_arguments:
    case Slot::Kind::kClosure_instantiator_type_arguments:
    case Slot::Kind::kClosure_hash:
    case Slot::Kind::kCapturedVariable:
    case Slot::Kind::kDartField:
    case Slot::Kind::kPointer_c_memory_address:
      return false;
  }
  UNREACHABLE();
  return false;
}

bool LoadFieldInstr::IsFixedLengthArrayCid(intptr_t cid) {
  if (RawObject::IsTypedDataClassId(cid) ||
      RawObject::IsExternalTypedDataClassId(cid)) {
    return true;
  }

  switch (cid) {
    case kArrayCid:
    case kImmutableArrayCid:
      return true;
    default:
      return false;
  }
}

bool LoadFieldInstr::IsTypedDataViewFactory(const Function& function) {
  auto kind = MethodRecognizer::RecognizeKind(function);
  switch (kind) {
    case MethodRecognizer::kTypedData_ByteDataView_factory:
    case MethodRecognizer::kTypedData_Int8ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint8ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint8ClampedArrayView_factory:
    case MethodRecognizer::kTypedData_Int16ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint16ArrayView_factory:
    case MethodRecognizer::kTypedData_Int32ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint32ArrayView_factory:
    case MethodRecognizer::kTypedData_Int64ArrayView_factory:
    case MethodRecognizer::kTypedData_Uint64ArrayView_factory:
    case MethodRecognizer::kTypedData_Float32ArrayView_factory:
    case MethodRecognizer::kTypedData_Float64ArrayView_factory:
    case MethodRecognizer::kTypedData_Float32x4ArrayView_factory:
    case MethodRecognizer::kTypedData_Int32x4ArrayView_factory:
    case MethodRecognizer::kTypedData_Float64x2ArrayView_factory:
      return true;
    default:
      return false;
  }
}

Definition* ConstantInstr::Canonicalize(FlowGraph* flow_graph) {
  return HasUses() ? this : NULL;
}

// A math unary instruction has a side effect (exception
// thrown) if the argument is not a number.
// TODO(srdjan): eliminate if has no uses and input is guaranteed to be number.
Definition* MathUnaryInstr::Canonicalize(FlowGraph* flow_graph) {
  return this;
}

bool LoadFieldInstr::TryEvaluateLoad(const Object& instance,
                                     const Slot& field,
                                     Object* result) {
  switch (field.kind()) {
    case Slot::Kind::kDartField:
      return TryEvaluateLoad(instance, field.field(), result);

    case Slot::Kind::kArgumentsDescriptor_type_args_len:
      if (instance.IsArray() && Array::Cast(instance).IsImmutable()) {
        ArgumentsDescriptor desc(Array::Cast(instance));
        *result = Smi::New(desc.TypeArgsLen());
        return true;
      }
      return false;

    default:
      break;
  }
  return false;
}

bool LoadFieldInstr::TryEvaluateLoad(const Object& instance,
                                     const Field& field,
                                     Object* result) {
  if (!field.is_final() || !instance.IsInstance()) {
    return false;
  }

  // Check that instance really has the field which we
  // are trying to load from.
  Class& cls = Class::Handle(instance.clazz());
  while (cls.raw() != Class::null() && cls.raw() != field.Owner()) {
    cls = cls.SuperClass();
  }
  if (cls.raw() != field.Owner()) {
    // Failed to find the field in class or its superclasses.
    return false;
  }

  // Object has the field: execute the load.
  *result = Instance::Cast(instance).GetField(field);
  return true;
}

bool LoadFieldInstr::Evaluate(const Object& instance, Object* result) {
  return TryEvaluateLoad(instance, slot(), result);
}

Definition* LoadFieldInstr::Canonicalize(FlowGraph* flow_graph) {
  if (!HasUses()) return nullptr;

  if (IsImmutableLengthLoad()) {
    Definition* array = instance()->definition()->OriginalDefinition();
    if (StaticCallInstr* call = array->AsStaticCall()) {
      // For fixed length arrays if the array is the result of a known
      // constructor call we can replace the length load with the length
      // argument passed to the constructor.
      if (call->is_known_list_constructor() &&
          IsFixedLengthArrayCid(call->Type()->ToCid())) {
        return call->ArgumentAt(1);
      } else if (call->function().recognized_kind() ==
                 MethodRecognizer::kByteDataFactory) {
        // Similarly, we check for the ByteData constructor and forward its
        // explicit length argument appropriately.
        return call->ArgumentAt(1);
      } else if (IsTypedDataViewFactory(call->function())) {
        // Typed data view factories all take three arguments (after
        // the implicit type arguments parameter):
        //
        // 1) _TypedList buffer -- the underlying data for the view
        // 2) int offsetInBytes -- the offset into the buffer to start viewing
        // 3) int length        -- the number of elements in the view
        //
        // Here, we forward the third.
        return call->ArgumentAt(3);
      }
    } else if (CreateArrayInstr* create_array = array->AsCreateArray()) {
      if (slot().kind() == Slot::Kind::kArray_length) {
        return create_array->num_elements()->definition();
      }
    } else if (LoadFieldInstr* load_array = array->AsLoadField()) {
      // For arrays with guarded lengths, replace the length load
      // with a constant.
      const Slot& slot = load_array->slot();
      if (slot.IsDartField()) {
        if (slot.field().guarded_list_length() >= 0) {
          return flow_graph->GetConstant(
              Smi::Handle(Smi::New(slot.field().guarded_list_length())));
        }
      }
    }
  } else if (slot().kind() == Slot::Kind::kTypedDataView_data) {
    // This case cover the first explicit argument to typed data view
    // factories, the data (buffer).
    Definition* array = instance()->definition()->OriginalDefinition();
    if (StaticCallInstr* call = array->AsStaticCall()) {
      if (IsTypedDataViewFactory(call->function())) {
        return call->ArgumentAt(1);
      }
    }
  } else if (slot().kind() == Slot::Kind::kTypedDataView_offset_in_bytes) {
    // This case cover the second explicit argument to typed data view
    // factories, the offset into the buffer.
    Definition* array = instance()->definition()->OriginalDefinition();
    if (StaticCallInstr* call = array->AsStaticCall()) {
      if (IsTypedDataViewFactory(call->function())) {
        return call->ArgumentAt(2);
      } else if (call->function().recognized_kind() ==
                 MethodRecognizer::kByteDataFactory) {
        // A _ByteDataView returned from the ByteData constructor always
        // has an offset of 0.
        return flow_graph->GetConstant(Smi::Handle(Smi::New(0)));
      }
    }
  } else if (slot().IsTypeArguments()) {
    Definition* array = instance()->definition()->OriginalDefinition();
    if (StaticCallInstr* call = array->AsStaticCall()) {
      if (call->is_known_list_constructor()) {
        return call->ArgumentAt(0);
      } else if (IsTypedDataViewFactory(call->function())) {
        return flow_graph->constant_null();
      }
      switch (call->function().recognized_kind()) {
        case MethodRecognizer::kByteDataFactory:
        case MethodRecognizer::kLinkedHashMap_getData:
          return flow_graph->constant_null();
        default:
          break;
      }
    } else if (CreateArrayInstr* create_array = array->AsCreateArray()) {
      return create_array->element_type()->definition();
    } else if (LoadFieldInstr* load_array = array->AsLoadField()) {
      const Slot& slot = load_array->slot();
      switch (slot.kind()) {
        case Slot::Kind::kDartField: {
          // For trivially exact fields we know that type arguments match
          // static type arguments exactly.
          const Field& field = slot.field();
          if (field.static_type_exactness_state().IsTriviallyExact()) {
            return flow_graph->GetConstant(TypeArguments::Handle(
                AbstractType::Handle(field.type()).arguments()));
          }
          break;
        }

        case Slot::Kind::kLinkedHashMap_data:
          return flow_graph->constant_null();

        default:
          break;
      }
    }
  }

  // Try folding away loads from constant objects.
  if (instance()->BindsToConstant()) {
    Object& result = Object::Handle();
    if (Evaluate(instance()->BoundConstant(), &result)) {
      if (result.IsSmi() || result.IsOld()) {
        return flow_graph->GetConstant(result);
      }
    }
  }

  return this;
}

Definition* AssertBooleanInstr::Canonicalize(FlowGraph* flow_graph) {
  if (FLAG_eliminate_type_checks) {
    if (value()->Type()->ToCid() == kBoolCid) {
      return value()->definition();
    }

    // In strong mode type is already verified either by static analysis
    // or runtime checks, so AssertBoolean just ensures that value is not null.
    if (!value()->Type()->is_nullable()) {
      return value()->definition();
    }
  }

  return this;
}

Definition* AssertAssignableInstr::Canonicalize(FlowGraph* flow_graph) {
  if (FLAG_eliminate_type_checks &&
      value()->Type()->IsAssignableTo(dst_type())) {
    return value()->definition();
  }
  if (dst_type().IsInstantiated()) {
    return this;
  }

  // For uninstantiated target types: If the instantiator and function
  // type arguments are constant, instantiate the target type here.
  // Note: these constant type arguments might not necessarily correspond
  // to the correct instantiator because AssertAssignable might
  // be located in the unreachable part of the graph (e.g.
  // it might be dominated by CheckClass that always fails).
  // This means that the code below must guard against such possibility.
  Zone* Z = Thread::Current()->zone();

  const TypeArguments* instantiator_type_args = nullptr;
  const TypeArguments* function_type_args = nullptr;

  if (instantiator_type_arguments()->BindsToConstant()) {
    const Object& val = instantiator_type_arguments()->BoundConstant();
    instantiator_type_args = (val.raw() == TypeArguments::null())
                                 ? &TypeArguments::null_type_arguments()
                                 : &TypeArguments::Cast(val);
  }

  if (function_type_arguments()->BindsToConstant()) {
    const Object& val = function_type_arguments()->BoundConstant();
    function_type_args =
        (val.raw() == TypeArguments::null())
            ? &TypeArguments::null_type_arguments()
            : &TypeArguments::Cast(function_type_arguments()->BoundConstant());
  }

  // If instantiator_type_args are not constant try to match the pattern
  // obj.field.:type_arguments where field's static type exactness state
  // tells us that all values stored in the field have exact superclass.
  // In this case we know the prefix of the actual type arguments vector
  // and can try to instantiate the type using just the prefix.
  //
  // Note: TypeParameter::InstantiateFrom returns an error if we try
  // to instantiate it from a vector that is too short.
  if (instantiator_type_args == nullptr) {
    if (LoadFieldInstr* load_type_args =
            instantiator_type_arguments()->definition()->AsLoadField()) {
      if (load_type_args->slot().IsTypeArguments()) {
        if (LoadFieldInstr* load_field = load_type_args->instance()
                                             ->definition()
                                             ->OriginalDefinition()
                                             ->AsLoadField()) {
          if (load_field->slot().IsDartField() &&
              load_field->slot()
                  .field()
                  .static_type_exactness_state()
                  .IsHasExactSuperClass()) {
            instantiator_type_args = &TypeArguments::Handle(
                Z, AbstractType::Handle(Z, load_field->slot().field().type())
                       .arguments());
          }
        }
      }
    }
  }

  if ((instantiator_type_args != nullptr) && (function_type_args != nullptr)) {
    AbstractType& new_dst_type = AbstractType::Handle(
        Z,
        dst_type().InstantiateFrom(*instantiator_type_args, *function_type_args,
                                   kAllFree, nullptr, Heap::kOld));
    if (new_dst_type.IsNull()) {
      // Failed instantiation in dead code.
      return this;
    }
    if (new_dst_type.IsTypeRef()) {
      new_dst_type = TypeRef::Cast(new_dst_type).type();
    }
    new_dst_type = new_dst_type.Canonicalize();

    // Successfully instantiated destination type: update the type attached
    // to this instruction and set type arguments to null because we no
    // longer need them (the type was instantiated).
    set_dst_type(new_dst_type);
    instantiator_type_arguments()->BindTo(flow_graph->constant_null());
    function_type_arguments()->BindTo(flow_graph->constant_null());

    if (new_dst_type.IsDynamicType() || new_dst_type.IsObjectType() ||
        (FLAG_eliminate_type_checks &&
         value()->Type()->IsAssignableTo(new_dst_type))) {
      return value()->definition();
    }
  }
  return this;
}

Definition* InstantiateTypeArgumentsInstr::Canonicalize(FlowGraph* flow_graph) {
  return HasUses() ? this : NULL;
}

LocationSummary* DebugStepCheckInstr::MakeLocationSummary(Zone* zone,
                                                          bool opt) const {
  const intptr_t kNumInputs = 0;
  const intptr_t kNumTemps = 0;
  LocationSummary* locs = new (zone)
      LocationSummary(zone, kNumInputs, kNumTemps, LocationSummary::kCall);
  return locs;
}

Instruction* DebugStepCheckInstr::Canonicalize(FlowGraph* flow_graph) {
  return NULL;
}

Definition* BoxInstr::Canonicalize(FlowGraph* flow_graph) {
  if (input_use_list() == nullptr) {
    // Environments can accommodate any representation. No need to box.
    return value()->definition();
  }

  // Fold away Box<rep>(Unbox<rep>(v)) if value is known to be of the
  // right class.
  UnboxInstr* unbox_defn = value()->definition()->AsUnbox();
  if ((unbox_defn != NULL) &&
      (unbox_defn->representation() == from_representation()) &&
      (unbox_defn->value()->Type()->ToCid() == Type()->ToCid())) {
    return unbox_defn->value()->definition();
  }

  return this;
}

bool BoxIntegerInstr::ValueFitsSmi() const {
  Range* range = value()->definition()->range();
  return RangeUtils::Fits(range, RangeBoundary::kRangeBoundarySmi);
}

Definition* BoxIntegerInstr::Canonicalize(FlowGraph* flow_graph) {
  if (input_use_list() == nullptr) {
    // Environments can accommodate any representation. No need to box.
    return value()->definition();
  }

  return this;
}

Definition* BoxInt64Instr::Canonicalize(FlowGraph* flow_graph) {
  Definition* replacement = BoxIntegerInstr::Canonicalize(flow_graph);
  if (replacement != this) {
    return replacement;
  }

  IntConverterInstr* conv = value()->definition()->AsIntConverter();
  if (conv != NULL) {
    Definition* replacement = this;

    switch (conv->from()) {
      case kUnboxedInt32:
        replacement = new BoxInt32Instr(conv->value()->CopyWithType());
        break;
      case kUnboxedUint32:
        replacement = new BoxUint32Instr(conv->value()->CopyWithType());
        break;
      default:
        UNREACHABLE();
        break;
    }

    if (replacement != this) {
      flow_graph->InsertBefore(this, replacement, NULL, FlowGraph::kValue);
    }

    return replacement;
  }

  return this;
}

Definition* UnboxInstr::Canonicalize(FlowGraph* flow_graph) {
  if (!HasUses() && !CanDeoptimize()) return NULL;

  // Fold away Unbox<rep>(Box<rep>(v)).
  BoxInstr* box_defn = value()->definition()->AsBox();
  if ((box_defn != NULL) &&
      (box_defn->from_representation() == representation())) {
    return box_defn->value()->definition();
  }

  if (representation() == kUnboxedDouble && value()->BindsToConstant()) {
    UnboxedConstantInstr* uc = NULL;

    const Object& val = value()->BoundConstant();
    if (val.IsSmi()) {
      const Double& double_val = Double::ZoneHandle(
          flow_graph->zone(),
          Double::NewCanonical(Smi::Cast(val).AsDoubleValue()));
      uc = new UnboxedConstantInstr(double_val, kUnboxedDouble);
    } else if (val.IsDouble()) {
      uc = new UnboxedConstantInstr(val, kUnboxedDouble);
    }

    if (uc != NULL) {
      flow_graph->InsertBefore(this, uc, NULL, FlowGraph::kValue);
      return uc;
    }
  }

  return this;
}

Definition* UnboxIntegerInstr::Canonicalize(FlowGraph* flow_graph) {
  if (!HasUses() && !CanDeoptimize()) return NULL;

  // Fold away UnboxInteger<rep_to>(BoxInteger<rep_from>(v)).
  BoxIntegerInstr* box_defn = value()->definition()->AsBoxInteger();
  if (box_defn != NULL) {
    Representation from_representation =
        box_defn->value()->definition()->representation();
    if (from_representation == representation()) {
      return box_defn->value()->definition();
    } else if (from_representation != kTagged) {
      // Only operate on explicit unboxed operands.
      IntConverterInstr* converter = new IntConverterInstr(
          from_representation, representation(),
          box_defn->value()->CopyWithType(),
          (representation() == kUnboxedInt32) ? GetDeoptId() : DeoptId::kNone);
      // TODO(vegorov): marking resulting converter as truncating when
      // unboxing can't deoptimize is a workaround for the missing
      // deoptimization environment when we insert converter after
      // EliminateEnvironments and there is a mismatch between predicates
      // UnboxIntConverterInstr::CanDeoptimize and UnboxInt32::CanDeoptimize.
      if ((representation() == kUnboxedInt32) &&
          (is_truncating() || !CanDeoptimize())) {
        converter->mark_truncating();
      }
      flow_graph->InsertBefore(this, converter, env(), FlowGraph::kValue);
      return converter;
    }
  }

  return this;
}

Definition* UnboxInt32Instr::Canonicalize(FlowGraph* flow_graph) {
  Definition* replacement = UnboxIntegerInstr::Canonicalize(flow_graph);
  if (replacement != this) {
    return replacement;
  }

  ConstantInstr* c = value()->definition()->AsConstant();
  if ((c != NULL) && c->value().IsSmi()) {
    if (!is_truncating()) {
      // Check that constant fits into 32-bit integer.
      const int64_t value = static_cast<int64_t>(Smi::Cast(c->value()).Value());
      if (!Utils::IsInt(32, value)) {
        return this;
      }
    }

    UnboxedConstantInstr* uc =
        new UnboxedConstantInstr(c->value(), kUnboxedInt32);
    if (c->range() != NULL) {
      uc->set_range(*c->range());
    }
    flow_graph->InsertBefore(this, uc, NULL, FlowGraph::kValue);
    return uc;
  }

  return this;
}

Definition* UnboxInt64Instr::Canonicalize(FlowGraph* flow_graph) {
  Definition* replacement = UnboxIntegerInstr::Canonicalize(flow_graph);
  if (replacement != this) {
    return replacement;
  }

// Currently we perform this only on 64-bit architectures and not on simdbc64
// (on simdbc64 the [UnboxedConstantInstr] handling is only implemented for
//  doubles and causes a bailout for everthing else)
#if !defined(TARGET_ARCH_DBC)
  if (compiler::target::kBitsPerWord == 64) {
    ConstantInstr* c = value()->definition()->AsConstant();
    if (c != NULL && (c->value().IsSmi() || c->value().IsMint())) {
      UnboxedConstantInstr* uc =
          new UnboxedConstantInstr(c->value(), kUnboxedInt64);
      if (c->range() != NULL) {
        uc->set_range(*c->range());
      }
      flow_graph->InsertBefore(this, uc, NULL, FlowGraph::kValue);
      return uc;
    }
  }
#endif  // !defined(TARGET_ARCH_DBC)

  return this;
}

Definition* IntConverterInstr::Canonicalize(FlowGraph* flow_graph) {
  if (!HasUses()) return NULL;

  IntConverterInstr* box_defn = value()->definition()->AsIntConverter();
  if ((box_defn != NULL) && (box_defn->representation() == from())) {
    if (box_defn->from() == to()) {
      // Do not erase truncating conversions from 64-bit value to 32-bit values
      // because such conversions erase upper 32 bits.
      if ((box_defn->from() == kUnboxedInt64) && box_defn->is_truncating()) {
        return this;
      }
      return box_defn->value()->definition();
    }

    IntConverterInstr* converter = new IntConverterInstr(
        box_defn->from(), representation(), box_defn->value()->CopyWithType(),
        (to() == kUnboxedInt32) ? GetDeoptId() : DeoptId::kNone);
    if ((representation() == kUnboxedInt32) && is_truncating()) {
      converter->mark_truncating();
    }
    flow_graph->InsertBefore(this, converter, env(), FlowGraph::kValue);
    return converter;
  }

  UnboxInt64Instr* unbox_defn = value()->definition()->AsUnboxInt64();
  if (unbox_defn != NULL && (from() == kUnboxedInt64) &&
      (to() == kUnboxedInt32) && unbox_defn->HasOnlyInputUse(value())) {
    // TODO(vegorov): there is a duplication of code between UnboxedIntCoverter
    // and code path that unboxes Mint into Int32. We should just schedule
    // these instructions close to each other instead of fusing them.
    Definition* replacement =
        new UnboxInt32Instr(is_truncating() ? UnboxInt32Instr::kTruncate
                                            : UnboxInt32Instr::kNoTruncation,
                            unbox_defn->value()->CopyWithType(), GetDeoptId());
    flow_graph->InsertBefore(this, replacement, env(), FlowGraph::kValue);
    return replacement;
  }

  return this;
}

// Tests for a FP comparison that cannot be negated
// (to preserve NaN semantics).
static bool IsFpCompare(ComparisonInstr* comp) {
  if (comp->IsRelationalOp()) {
    return comp->operation_cid() == kDoubleCid;
  }
  return false;
}

Definition* BooleanNegateInstr::Canonicalize(FlowGraph* flow_graph) {
  Definition* defn = value()->definition();
  // Convert e.g. !(x > y) into (x <= y) for non-FP x, y.
  if (defn->IsComparison() && defn->HasOnlyUse(value()) &&
      defn->Type()->ToCid() == kBoolCid) {
    ComparisonInstr* comp = defn->AsComparison();
    if (!IsFpCompare(comp)) {
      comp->NegateComparison();
      return defn;
    }
  }
  return this;
}

static bool MayBeBoxableNumber(intptr_t cid) {
  return (cid == kDynamicCid) || (cid == kMintCid) || (cid == kDoubleCid);
}

static bool MayBeNumber(CompileType* type) {
  if (type->IsNone()) {
    return false;
  }
  auto& compile_type = AbstractType::Handle(type->ToAbstractType()->raw());
  if (compile_type.IsType() &&
      Class::Handle(compile_type.type_class()).IsFutureOrClass()) {
    const auto& type_args = TypeArguments::Handle(compile_type.arguments());
    if (type_args.IsNull()) {
      return true;
    }
    compile_type = type_args.TypeAt(0);
  }
  // Note that type 'Number' is a subtype of itself.
  return compile_type.IsTopType() || compile_type.IsTypeParameter() ||
         compile_type.IsSubtypeOf(Type::Handle(Type::Number()), Heap::kOld);
}

// Returns a replacement for a strict comparison and signals if the result has
// to be negated.
static Definition* CanonicalizeStrictCompare(StrictCompareInstr* compare,
                                             bool* negated,
                                             bool is_branch) {
  // Use propagated cid and type information to eliminate number checks.
  // If one of the inputs is not a boxable number (Mint, Double), or
  // is not a subtype of num, no need for number checks.
  if (compare->needs_number_check()) {
    if (!MayBeBoxableNumber(compare->left()->Type()->ToCid()) ||
        !MayBeBoxableNumber(compare->right()->Type()->ToCid())) {
      compare->set_needs_number_check(false);
    } else if (!MayBeNumber(compare->left()->Type()) ||
               !MayBeNumber(compare->right()->Type())) {
      compare->set_needs_number_check(false);
    }
  }
  *negated = false;
  PassiveObject& constant = PassiveObject::Handle();
  Value* other = NULL;
  if (compare->right()->BindsToConstant()) {
    constant = compare->right()->BoundConstant().raw();
    other = compare->left();
  } else if (compare->left()->BindsToConstant()) {
    constant = compare->left()->BoundConstant().raw();
    other = compare->right();
  } else {
    return compare;
  }

  const bool can_merge = is_branch || (other->Type()->ToCid() == kBoolCid);
  Definition* other_defn = other->definition();
  Token::Kind kind = compare->kind();
  // Handle e === true.
  if ((kind == Token::kEQ_STRICT) && (constant.raw() == Bool::True().raw()) &&
      can_merge) {
    return other_defn;
  }
  // Handle e !== false.
  if ((kind == Token::kNE_STRICT) && (constant.raw() == Bool::False().raw()) &&
      can_merge) {
    return other_defn;
  }
  // Handle e !== true.
  if ((kind == Token::kNE_STRICT) && (constant.raw() == Bool::True().raw()) &&
      other_defn->IsComparison() && can_merge &&
      other_defn->HasOnlyUse(other)) {
    ComparisonInstr* comp = other_defn->AsComparison();
    if (!IsFpCompare(comp)) {
      *negated = true;
      return other_defn;
    }
  }
  // Handle e === false.
  if ((kind == Token::kEQ_STRICT) && (constant.raw() == Bool::False().raw()) &&
      other_defn->IsComparison() && can_merge &&
      other_defn->HasOnlyUse(other)) {
    ComparisonInstr* comp = other_defn->AsComparison();
    if (!IsFpCompare(comp)) {
      *negated = true;
      return other_defn;
    }
  }
  return compare;
}

static bool BindsToGivenConstant(Value* v, intptr_t expected) {
  return v->BindsToConstant() && v->BoundConstant().IsSmi() &&
         (Smi::Cast(v->BoundConstant()).Value() == expected);
}

// Recognize patterns (a & b) == 0 and (a & 2^n) != 2^n.
static bool RecognizeTestPattern(Value* left, Value* right, bool* negate) {
  if (!right->BindsToConstant() || !right->BoundConstant().IsSmi()) {
    return false;
  }

  const intptr_t value = Smi::Cast(right->BoundConstant()).Value();
  if ((value != 0) && !Utils::IsPowerOfTwo(value)) {
    return false;
  }

  BinarySmiOpInstr* mask_op = left->definition()->AsBinarySmiOp();
  if ((mask_op == NULL) || (mask_op->op_kind() != Token::kBIT_AND) ||
      !mask_op->HasOnlyUse(left)) {
    return false;
  }

  if (value == 0) {
    // Recognized (a & b) == 0 pattern.
    *negate = false;
    return true;
  }

  // Recognize
  if (BindsToGivenConstant(mask_op->left(), value) ||
      BindsToGivenConstant(mask_op->right(), value)) {
    // Recognized (a & 2^n) == 2^n pattern. It's equivalent to (a & 2^n) != 0
    // so we need to negate original comparison.
    *negate = true;
    return true;
  }

  return false;
}

Instruction* BranchInstr::Canonicalize(FlowGraph* flow_graph) {
  Zone* zone = flow_graph->zone();
  // Only handle strict-compares.
  if (comparison()->IsStrictCompare()) {
    bool negated = false;
    Definition* replacement = CanonicalizeStrictCompare(
        comparison()->AsStrictCompare(), &negated, /* is_branch = */ true);
    if (replacement == comparison()) {
      return this;
    }
    ComparisonInstr* comp = replacement->AsComparison();
    if ((comp == NULL) || comp->CanDeoptimize() ||
        comp->HasUnmatchedInputRepresentations()) {
      return this;
    }

    // Replace the comparison if the replacement is used at this branch,
    // and has exactly one use.
    Value* use = comp->input_use_list();
    if ((use->instruction() == this) && comp->HasOnlyUse(use)) {
      if (negated) {
        comp->NegateComparison();
      }
      RemoveEnvironment();
      flow_graph->CopyDeoptTarget(this, comp);
      // Unlink environment from the comparison since it is copied to the
      // branch instruction.
      comp->RemoveEnvironment();

      comp->RemoveFromGraph();
      SetComparison(comp);
      if (FLAG_trace_optimization) {
        THR_Print("Merging comparison v%" Pd "\n", comp->ssa_temp_index());
      }
      // Clear the comparison's temp index and ssa temp index since the
      // value of the comparison is not used outside the branch anymore.
      ASSERT(comp->input_use_list() == NULL);
      comp->ClearSSATempIndex();
      comp->ClearTempIndex();
    }
  } else if (comparison()->IsEqualityCompare() &&
             comparison()->operation_cid() == kSmiCid) {
    BinarySmiOpInstr* bit_and = NULL;
    bool negate = false;
    if (RecognizeTestPattern(comparison()->left(), comparison()->right(),
                             &negate)) {
      bit_and = comparison()->left()->definition()->AsBinarySmiOp();
    } else if (RecognizeTestPattern(comparison()->right(), comparison()->left(),
                                    &negate)) {
      bit_and = comparison()->right()->definition()->AsBinarySmiOp();
    }
    if (bit_and != NULL) {
      if (FLAG_trace_optimization) {
        THR_Print("Merging test smi v%" Pd "\n", bit_and->ssa_temp_index());
      }
      TestSmiInstr* test = new TestSmiInstr(
          comparison()->token_pos(),
          negate ? Token::NegateComparison(comparison()->kind())
                 : comparison()->kind(),
          bit_and->left()->Copy(zone), bit_and->right()->Copy(zone));
      ASSERT(!CanDeoptimize());
      RemoveEnvironment();
      flow_graph->CopyDeoptTarget(this, bit_and);
      SetComparison(test);
      bit_and->RemoveFromGraph();
    }
  }
  return this;
}

Definition* StrictCompareInstr::Canonicalize(FlowGraph* flow_graph) {
  if (!HasUses()) return NULL;
  bool negated = false;
  Definition* replacement = CanonicalizeStrictCompare(this, &negated,
                                                      /* is_branch = */ false);
  if (negated && replacement->IsComparison()) {
    ASSERT(replacement != this);
    replacement->AsComparison()->NegateComparison();
  }
  return replacement;
}

Instruction* CheckClassInstr::Canonicalize(FlowGraph* flow_graph) {
  const intptr_t value_cid = value()->Type()->ToCid();
  if (value_cid == kDynamicCid) {
    return this;
  }

  return cids().HasClassId(value_cid) ? NULL : this;
}

Definition* LoadClassIdInstr::Canonicalize(FlowGraph* flow_graph) {
  const intptr_t cid = object()->Type()->ToCid();
  if (cid != kDynamicCid) {
    const auto& smi = Smi::ZoneHandle(flow_graph->zone(), Smi::New(cid));
    return flow_graph->GetConstant(smi);
  }
  return this;
}

Instruction* CheckClassIdInstr::Canonicalize(FlowGraph* flow_graph) {
  if (value()->BindsToConstant()) {
    const Object& constant_value = value()->BoundConstant();
    if (constant_value.IsSmi() &&
        cids_.Contains(Smi::Cast(constant_value).Value())) {
      return NULL;
    }
  }
  return this;
}

TestCidsInstr::TestCidsInstr(TokenPosition token_pos,
                             Token::Kind kind,
                             Value* value,
                             const ZoneGrowableArray<intptr_t>& cid_results,
                             intptr_t deopt_id)
    : TemplateComparison(token_pos, kind, deopt_id),
      cid_results_(cid_results),
      licm_hoisted_(false) {
  ASSERT((kind == Token::kIS) || (kind == Token::kISNOT));
  SetInputAt(0, value);
  set_operation_cid(kObjectCid);
#ifdef DEBUG
  ASSERT(cid_results[0] == kSmiCid);
  if (deopt_id == DeoptId::kNone) {
    // The entry for Smi can be special, but all other entries have
    // to match in the no-deopt case.
    for (intptr_t i = 4; i < cid_results.length(); i += 2) {
      ASSERT(cid_results[i + 1] == cid_results[3]);
    }
  }
#endif
}

Definition* TestCidsInstr::Canonicalize(FlowGraph* flow_graph) {
  CompileType* in_type = left()->Type();
  intptr_t cid = in_type->ToCid();
  if (cid == kDynamicCid) return this;

  const ZoneGrowableArray<intptr_t>& data = cid_results();
  const intptr_t true_result = (kind() == Token::kIS) ? 1 : 0;
  for (intptr_t i = 0; i < data.length(); i += 2) {
    if (data[i] == cid) {
      return (data[i + 1] == true_result)
                 ? flow_graph->GetConstant(Bool::True())
                 : flow_graph->GetConstant(Bool::False());
    }
  }

  if (!CanDeoptimize()) {
    ASSERT(deopt_id() == DeoptId::kNone);
    return (data[data.length() - 1] == true_result)
               ? flow_graph->GetConstant(Bool::False())
               : flow_graph->GetConstant(Bool::True());
  }

  // TODO(sra): Handle nullable input, possibly canonicalizing to a compare
  // against `null`.
  return this;
}

Instruction* GuardFieldClassInstr::Canonicalize(FlowGraph* flow_graph) {
  if (field().guarded_cid() == kDynamicCid) {
    return NULL;  // Nothing to guard.
  }

  if (field().is_nullable() && value()->Type()->IsNull()) {
    return NULL;
  }

  const intptr_t cid = field().is_nullable() ? value()->Type()->ToNullableCid()
                                             : value()->Type()->ToCid();
  if (field().guarded_cid() == cid) {
    return NULL;  // Value is guaranteed to have this cid.
  }

  return this;
}

Instruction* GuardFieldLengthInstr::Canonicalize(FlowGraph* flow_graph) {
  if (!field().needs_length_check()) {
    return NULL;  // Nothing to guard.
  }

  const intptr_t expected_length = field().guarded_list_length();
  if (expected_length == Field::kUnknownFixedLength) {
    return this;
  }

  // Check if length is statically known.
  StaticCallInstr* call = value()->definition()->AsStaticCall();
  if (call == NULL) {
    return this;
  }

  ConstantInstr* length = NULL;
  if (call->is_known_list_constructor() &&
      LoadFieldInstr::IsFixedLengthArrayCid(call->Type()->ToCid())) {
    length = call->ArgumentAt(1)->AsConstant();
  } else if (call->function().recognized_kind() ==
             MethodRecognizer::kByteDataFactory) {
    length = call->ArgumentAt(1)->AsConstant();
  } else if (LoadFieldInstr::IsTypedDataViewFactory(call->function())) {
    length = call->ArgumentAt(3)->AsConstant();
  }
  if ((length != NULL) && length->value().IsSmi() &&
      Smi::Cast(length->value()).Value() == expected_length) {
    return NULL;  // Expected length matched.
  }

  return this;
}

Instruction* GuardFieldTypeInstr::Canonicalize(FlowGraph* flow_graph) {
  return field().static_type_exactness_state().NeedsFieldGuard() ? this
                                                                 : nullptr;
}

Instruction* CheckSmiInstr::Canonicalize(FlowGraph* flow_graph) {
  return (value()->Type()->ToCid() == kSmiCid) ? NULL : this;
}

Instruction* CheckEitherNonSmiInstr::Canonicalize(FlowGraph* flow_graph) {
  if ((left()->Type()->ToCid() == kDoubleCid) ||
      (right()->Type()->ToCid() == kDoubleCid)) {
    return NULL;  // Remove from the graph.
  }
  return this;
}

Definition* CheckNullInstr::Canonicalize(FlowGraph* flow_graph) {
  return (!value()->Type()->is_nullable()) ? value()->definition() : this;
}

BoxInstr* BoxInstr::Create(Representation from, Value* value) {
  switch (from) {
    case kUnboxedInt32:
      return new BoxInt32Instr(value);

    case kUnboxedUint32:
      return new BoxUint32Instr(value);

    case kUnboxedInt64:
      return new BoxInt64Instr(value);

    case kUnboxedDouble:
    case kUnboxedFloat:
    case kUnboxedFloat32x4:
    case kUnboxedFloat64x2:
    case kUnboxedInt32x4:
      return new BoxInstr(from, value);

    default:
      UNREACHABLE();
      return NULL;
  }
}

UnboxInstr* UnboxInstr::Create(Representation to,
                               Value* value,
                               intptr_t deopt_id,
                               SpeculativeMode speculative_mode) {
  switch (to) {
    case kUnboxedInt32:
      // We must truncate if we can't deoptimize.
      return new UnboxInt32Instr(
          speculative_mode == SpeculativeMode::kNotSpeculative
              ? UnboxInt32Instr::kTruncate
              : UnboxInt32Instr::kNoTruncation,
          value, deopt_id, speculative_mode);

    case kUnboxedUint32:
      return new UnboxUint32Instr(value, deopt_id, speculative_mode);

    case kUnboxedInt64:
      return new UnboxInt64Instr(value, deopt_id, speculative_mode);

    case kUnboxedDouble:
    case kUnboxedFloat:
    case kUnboxedFloat32x4:
    case kUnboxedFloat64x2:
    case kUnboxedInt32x4:
      ASSERT(FlowGraphCompiler::SupportsUnboxedDoubles());
      return new UnboxInstr(to, value, deopt_id, speculative_mode);

    default:
      UNREACHABLE();
      return NULL;
  }
}

bool UnboxInstr::CanConvertSmi() const {
  switch (representation()) {
    case kUnboxedDouble:
    case kUnboxedFloat:
    case kUnboxedInt32:
    case kUnboxedInt64:
      return true;

    case kUnboxedFloat32x4:
    case kUnboxedFloat64x2:
    case kUnboxedInt32x4:
      return false;

    default:
      UNREACHABLE();
      return false;
  }
}

CallTargets* CallTargets::Create(Zone* zone, const ICData& ic_data) {
  CallTargets* targets = new (zone) CallTargets(zone);
  targets->CreateHelper(zone, ic_data, /* argument_number = */ 0,
                        /* include_targets = */ true);
  targets->Sort(OrderById);
  targets->MergeIntoRanges();
  return targets;
}

CallTargets* CallTargets::CreateAndExpand(Zone* zone, const ICData& ic_data) {
  CallTargets& targets = *new (zone) CallTargets(zone);
  targets.CreateHelper(zone, ic_data, /* argument_number = */ 0,
                       /* include_targets = */ true);
  targets.Sort(OrderById);

  Array& args_desc_array = Array::Handle(zone, ic_data.arguments_descriptor());
  ArgumentsDescriptor args_desc(args_desc_array);
  String& name = String::Handle(zone, ic_data.target_name());

  Function& fn = Function::Handle(zone);

  intptr_t length = targets.length();

  // Merging/extending cid ranges is also done in Cids::CreateAndExpand.
  // If changing this code, consider also adjusting Cids code.

  // Spread class-ids to preceding classes where a lookup yields the same
  // method.  A polymorphic target is not really the same method since its
  // behaviour depends on the receiver class-id, so we don't spread the
  // class-ids in that case.
  for (int idx = 0; idx < length; idx++) {
    int lower_limit_cid = (idx == 0) ? -1 : targets[idx - 1].cid_end;
    auto target_info = targets.TargetAt(idx);
    const Function& target = *target_info->target;
    if (MethodRecognizer::PolymorphicTarget(target)) continue;
    for (int i = target_info->cid_start - 1; i > lower_limit_cid; i--) {
      bool class_is_abstract = false;
      if (FlowGraphCompiler::LookupMethodFor(i, name, args_desc, &fn,
                                             &class_is_abstract) &&
          fn.raw() == target.raw()) {
        if (!class_is_abstract) {
          target_info->cid_start = i;
          target_info->exactness = StaticTypeExactnessState::NotTracking();
        }
      } else {
        break;
      }
    }
  }

  // Spread class-ids to following classes where a lookup yields the same
  // method.
  const intptr_t max_cid = Isolate::Current()->class_table()->NumCids();
  for (int idx = 0; idx < length; idx++) {
    int upper_limit_cid =
        (idx == length - 1) ? max_cid : targets[idx + 1].cid_start;
    auto target_info = targets.TargetAt(idx);
    const Function& target = *target_info->target;
    if (MethodRecognizer::PolymorphicTarget(target)) continue;
    // The code below makes attempt to avoid spreading class-id range
    // into a suffix that consists purely of abstract classes to
    // shorten the range.
    // However such spreading is beneficial when it allows to
    // merge to consequtive ranges.
    intptr_t cid_end_including_abstract = target_info->cid_end;
    for (int i = target_info->cid_end + 1; i < upper_limit_cid; i++) {
      bool class_is_abstract = false;
      if (FlowGraphCompiler::LookupMethodFor(i, name, args_desc, &fn,
                                             &class_is_abstract) &&
          fn.raw() == target.raw()) {
        cid_end_including_abstract = i;
        if (!class_is_abstract) {
          target_info->cid_end = i;
          target_info->exactness = StaticTypeExactnessState::NotTracking();
        }
      } else {
        break;
      }
    }

    // Check if we have a suffix that consists of abstract classes
    // and expand into it if that would allow us to merge this
    // range with subsequent range.
    if ((cid_end_including_abstract > target_info->cid_end) &&
        (idx < length - 1) &&
        ((cid_end_including_abstract + 1) == targets[idx + 1].cid_start) &&
        (target.raw() == targets.TargetAt(idx + 1)->target->raw())) {
      target_info->cid_end = cid_end_including_abstract;
      target_info->exactness = StaticTypeExactnessState::NotTracking();
    }
  }
  targets.MergeIntoRanges();
  return &targets;
}

void CallTargets::MergeIntoRanges() {
  // Merge adjacent class id ranges.
  int dest = 0;
  // We merge entries that dispatch to the same target, but polymorphic targets
  // are not really the same target since they depend on the class-id, so we
  // don't merge them.
  for (int src = 1; src < length(); src++) {
    const Function& target = *TargetAt(dest)->target;
    if (TargetAt(dest)->cid_end + 1 >= TargetAt(src)->cid_start &&
        target.raw() == TargetAt(src)->target->raw() &&
        !MethodRecognizer::PolymorphicTarget(target)) {
      TargetAt(dest)->cid_end = TargetAt(src)->cid_end;
      TargetAt(dest)->count += TargetAt(src)->count;
      TargetAt(dest)->exactness = StaticTypeExactnessState::NotTracking();
    } else {
      dest++;
      if (src != dest) {
        // Use cid_ranges_ instead of TargetAt when updating the pointer.
        cid_ranges_[dest] = TargetAt(src);
      }
    }
  }
  SetLength(dest + 1);
  Sort(OrderByFrequency);
}

void CallTargets::Print() const {
  for (intptr_t i = 0; i < length(); i++) {
    THR_Print("cid = [%" Pd ", %" Pd "], count = %" Pd ", target = %s\n",
              TargetAt(i)->cid_start, TargetAt(i)->cid_end, TargetAt(i)->count,
              TargetAt(i)->target->ToQualifiedCString());
  }
}

// Shared code generation methods (EmitNativeCode and
// MakeLocationSummary). Only assembly code that can be shared across all
// architectures can be used. Machine specific register allocation and code
// generation is located in intermediate_language_<arch>.cc

#define __ compiler->assembler()->

LocationSummary* GraphEntryInstr::MakeLocationSummary(Zone* zone,
                                                      bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

LocationSummary* JoinEntryInstr::MakeLocationSummary(Zone* zone,
                                                     bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

void JoinEntryInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  __ Bind(compiler->GetJumpLabel(this));
  if (!compiler->is_optimizing()) {
    compiler->AddCurrentDescriptor(RawPcDescriptors::kDeopt, GetDeoptId(),
                                   TokenPosition::kNoSource);
  }
  if (HasParallelMove()) {
    compiler->parallel_move_resolver()->EmitNativeCode(parallel_move());
  }
}

LocationSummary* TargetEntryInstr::MakeLocationSummary(Zone* zone,
                                                       bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

void TargetEntryInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  __ Bind(compiler->GetJumpLabel(this));

  // TODO(kusterman): Remove duplicate between
  // {TargetEntryInstr,FunctionEntryInstr}::EmitNativeCode.
  if (!compiler->is_optimizing()) {
#if !defined(TARGET_ARCH_DBC)
    // TODO(vegorov) re-enable edge counters on DBC if we consider them
    // beneficial for the quality of the optimized bytecode.
    if (compiler->NeedsEdgeCounter(this)) {
      compiler->EmitEdgeCounter(preorder_number());
    }
#endif

    // The deoptimization descriptor points after the edge counter code for
    // uniformity with ARM, where we can reuse pattern matching code that
    // matches backwards from the end of the pattern.
    compiler->AddCurrentDescriptor(RawPcDescriptors::kDeopt, GetDeoptId(),
                                   TokenPosition::kNoSource);
  }
  if (HasParallelMove()) {
    if (compiler::Assembler::EmittingComments()) {
      compiler->EmitComment(parallel_move());
    }
    compiler->parallel_move_resolver()->EmitNativeCode(parallel_move());
  }
}

LocationSummary* FunctionEntryInstr::MakeLocationSummary(
    Zone* zone,
    bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

void FunctionEntryInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
#if defined(TARGET_ARCH_X64)
  // Ensure the start of the monomorphic checked entry is 2-byte aligned (see
  // also Assembler::MonomorphicCheckedEntry()).
  if (__ CodeSize() % 2 == 1) {
    __ nop();
  }
#endif
  if (tag() == Instruction::kFunctionEntry) {
    __ Bind(compiler->GetJumpLabel(this));
  }

// In the AOT compiler we want to reduce code size, so generate no
// fall-through code in [FlowGraphCompiler::CompileGraph()].
// (As opposed to here where we don't check for the return value of
// [Intrinsify]).
  const Function& function = compiler->parsed_function().function();
  if (function.IsDynamicFunction()) {
    compiler->SpecialStatsBegin(CombinedCodeStatistics::kTagCheckedEntry);
    if (!FLAG_precompiled_mode) {
      __ MonomorphicCheckedEntryJIT();
    } else {
      __ MonomorphicCheckedEntryAOT();
    }
    compiler->SpecialStatsEnd(CombinedCodeStatistics::kTagCheckedEntry);
  }

  // NOTE: Because of the presence of multiple entry-points, we generate several
  // times the same intrinsification & frame setup. That's why we cannot rely on
  // the constant pool being `false` when we come in here.
#if defined(TARGET_USES_OBJECT_POOL)
  __ set_constant_pool_allowed(false);
#endif

  if (compiler->TryIntrinsify() && compiler->skip_body_compilation()) {
    return;
  }
  compiler->EmitPrologue();

#if defined(TARGET_USES_OBJECT_POOL)
  ASSERT(__ constant_pool_allowed());
#endif

  if (!compiler->is_optimizing()) {
#if !defined(TARGET_ARCH_DBC)
    // TODO(vegorov) re-enable edge counters on DBC if we consider them
    // beneficial for the quality of the optimized bytecode.
    if (compiler->NeedsEdgeCounter(this)) {
      compiler->EmitEdgeCounter(preorder_number());
    }
#endif

    // The deoptimization descriptor points after the edge counter code for
    // uniformity with ARM, where we can reuse pattern matching code that
    // matches backwards from the end of the pattern.
    compiler->AddCurrentDescriptor(RawPcDescriptors::kDeopt, GetDeoptId(),
                                   TokenPosition::kNoSource);
  }
  if (HasParallelMove()) {
    if (compiler::Assembler::EmittingComments()) {
      compiler->EmitComment(parallel_move());
    }
    compiler->parallel_move_resolver()->EmitNativeCode(parallel_move());
  }
}

LocationSummary* NativeEntryInstr::MakeLocationSummary(Zone* zone,
                                                       bool optimizing) const {
  UNREACHABLE();
}

LocationSummary* OsrEntryInstr::MakeLocationSummary(Zone* zone,
                                                    bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

void OsrEntryInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  ASSERT(!FLAG_precompiled_mode);
  ASSERT(compiler->is_optimizing());
  __ Bind(compiler->GetJumpLabel(this));

  // NOTE: Because the graph can have multiple entrypoints, we generate several
  // times the same intrinsification & frame setup. That's why we cannot rely on
  // the constant pool being `false` when we come in here.
#if defined(TARGET_USES_OBJECT_POOL)
  __ set_constant_pool_allowed(false);
#endif

  compiler->EmitPrologue();

#if defined(TARGET_USES_OBJECT_POOL)
  ASSERT(__ constant_pool_allowed());
#endif

  if (HasParallelMove()) {
    if (compiler::Assembler::EmittingComments()) {
      compiler->EmitComment(parallel_move());
    }
    compiler->parallel_move_resolver()->EmitNativeCode(parallel_move());
  }
}

void IndirectGotoInstr::ComputeOffsetTable() {
  if (GetBlock()->offset() < 0) {
    // Don't generate a table when contained in an unreachable block.
    return;
  }
  ASSERT(SuccessorCount() == offsets_.Length());
  intptr_t element_size = offsets_.ElementSizeInBytes();
  for (intptr_t i = 0; i < SuccessorCount(); i++) {
    TargetEntryInstr* target = SuccessorAt(i);
    intptr_t offset = target->offset();

    // The intermediate block might be compacted, if so, use the indirect entry.
    if (offset < 0) {
      // Optimizations might have modified the immediate target block, but it
      // must end with a goto to the indirect entry. Also, we can't use
      // last_instruction because 'target' is compacted/unreachable.
      Instruction* last = target->next();
      while (last != NULL && !last->IsGoto()) {
        last = last->next();
      }
      ASSERT(last);
      IndirectEntryInstr* ientry =
          last->AsGoto()->successor()->AsIndirectEntry();
      ASSERT(ientry != NULL);
      ASSERT(ientry->indirect_id() == i);
      offset = ientry->offset();
    }

    ASSERT(offset > 0);
    offsets_.SetInt32(i * element_size, offset);
  }
}

LocationSummary* IndirectEntryInstr::MakeLocationSummary(
    Zone* zone,
    bool optimizing) const {
  return JoinEntryInstr::MakeLocationSummary(zone, optimizing);
}

void IndirectEntryInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  JoinEntryInstr::EmitNativeCode(compiler);
}

LocationSummary* PhiInstr::MakeLocationSummary(Zone* zone,
                                               bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

void PhiInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  UNREACHABLE();
}

LocationSummary* RedefinitionInstr::MakeLocationSummary(Zone* zone,
                                                        bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

void RedefinitionInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  UNREACHABLE();
}

LocationSummary* ParameterInstr::MakeLocationSummary(Zone* zone,
                                                     bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

void ParameterInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  UNREACHABLE();
}

void NativeParameterInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
#if !defined(TARGET_ARCH_DBC)
  // The native entry frame has size -kExitLinkSlotFromFp. In order to access
  // the top of stack from above the entry frame, we add a constant to account
  // for the the two frame pointers and two return addresses of the entry frame.
  constexpr intptr_t kEntryFramePadding = 4;
  FrameRebase rebase(/*old_base=*/SPREG, /*new_base=*/FPREG,
                     -kExitLinkSlotFromEntryFp + kEntryFramePadding);
  const Location dst = locs()->out(0);
  const Location src = rebase.Rebase(loc_);
  NoTemporaryAllocator no_temp;
  compiler->EmitMove(dst, src, &no_temp);
#else
  UNREACHABLE();
#endif
}

LocationSummary* NativeParameterInstr::MakeLocationSummary(Zone* zone,
                                                           bool opt) const {
#if !defined(TARGET_ARCH_DBC)
  ASSERT(opt);
  Location input = Location::Any();
  if (representation() == kUnboxedInt64 && compiler::target::kWordSize < 8) {
    input = Location::Pair(Location::RequiresRegister(),
                           Location::RequiresFpuRegister());
  } else {
    input = RegisterKindForResult() == Location::kRegister
                ? Location::RequiresRegister()
                : Location::RequiresFpuRegister();
  }
  return LocationSummary::Make(zone, /*num_inputs=*/0, input,
                               LocationSummary::kNoCall);
#else
  UNREACHABLE();
#endif
}

bool ParallelMoveInstr::IsRedundant() const {
  for (intptr_t i = 0; i < moves_.length(); i++) {
    if (!moves_[i]->IsRedundant()) {
      return false;
    }
  }
  return true;
}

LocationSummary* ParallelMoveInstr::MakeLocationSummary(Zone* zone,
                                                        bool optimizing) const {
  return NULL;
}

void ParallelMoveInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  UNREACHABLE();
}

LocationSummary* ConstraintInstr::MakeLocationSummary(Zone* zone,
                                                      bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

void ConstraintInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  UNREACHABLE();
}

LocationSummary* MaterializeObjectInstr::MakeLocationSummary(
    Zone* zone,
    bool optimizing) const {
  UNREACHABLE();
  return NULL;
}

void MaterializeObjectInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  UNREACHABLE();
}

// This function should be kept in sync with
// FlowGraphCompiler::SlowPathEnvironmentFor().
void MaterializeObjectInstr::RemapRegisters(intptr_t* cpu_reg_slots,
                                            intptr_t* fpu_reg_slots) {
  if (registers_remapped_) {
    return;
  }
  registers_remapped_ = true;

  for (intptr_t i = 0; i < InputCount(); i++) {
    locations_[i] = LocationRemapForSlowPath(
        LocationAt(i), InputAt(i)->definition(), cpu_reg_slots, fpu_reg_slots);
  }
}

LocationSummary* SpecialParameterInstr::MakeLocationSummary(Zone* zone,
                                                            bool opt) const {
  // Only appears in initial definitions, never in normal code.
  UNREACHABLE();
  return NULL;
}

void SpecialParameterInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  // Only appears in initial definitions, never in normal code.
  UNREACHABLE();
}

LocationSummary* MakeTempInstr::MakeLocationSummary(Zone* zone,
                                                    bool optimizing) const {
  ASSERT(!optimizing);
  null_->InitializeLocationSummary(zone, optimizing);
  return null_->locs();
}

void MakeTempInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  ASSERT(!compiler->is_optimizing());
  null_->EmitNativeCode(compiler);
}

LocationSummary* DropTempsInstr::MakeLocationSummary(Zone* zone,
                                                     bool optimizing) const {
  ASSERT(!optimizing);
  return (InputCount() == 1)
             ? LocationSummary::Make(zone, 1, Location::SameAsFirstInput(),
                                     LocationSummary::kNoCall)
             : LocationSummary::Make(zone, 0, Location::NoLocation(),
                                     LocationSummary::kNoCall);
}

void DropTempsInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
#if defined(TARGET_ARCH_DBC)
  // On DBC the action of poping the TOS value and then pushing it
  // after all intermediates are poped is folded into a special
  // bytecode (DropR). On other architectures this is handled by
  // instruction prologue/epilogues.
  ASSERT(!compiler->is_optimizing());
  if ((InputCount() != 0) && HasTemp()) {
    __ DropR(num_temps());
  } else {
    __ Drop(num_temps() + ((InputCount() != 0) ? 1 : 0));
  }
#else
  ASSERT(!compiler->is_optimizing());
  // Assert that register assignment is correct.
  ASSERT((InputCount() == 0) || (locs()->out(0).reg() == locs()->in(0).reg()));
  __ Drop(num_temps());
#endif  // defined(TARGET_ARCH_DBC)
}

StrictCompareInstr::StrictCompareInstr(TokenPosition token_pos,
                                       Token::Kind kind,
                                       Value* left,
                                       Value* right,
                                       bool needs_number_check,
                                       intptr_t deopt_id)
    : TemplateComparison(token_pos, kind, deopt_id),
      needs_number_check_(needs_number_check) {
  ASSERT((kind == Token::kEQ_STRICT) || (kind == Token::kNE_STRICT));
  SetInputAt(0, left);
  SetInputAt(1, right);
}

LocationSummary* InstanceCallInstr::MakeLocationSummary(Zone* zone,
                                                        bool optimizing) const {
  return MakeCallSummary(zone);
}

// DBC does not use specialized inline cache stubs for smi operations.
#if !defined(TARGET_ARCH_DBC)
static RawCode* TwoArgsSmiOpInlineCacheEntry(Token::Kind kind) {
  if (!FLAG_two_args_smi_icd) {
    return Code::null();
  }
  switch (kind) {
    case Token::kADD:
      return StubCode::SmiAddInlineCache().raw();
    case Token::kLT:
      return StubCode::SmiLessInlineCache().raw();
    case Token::kEQ:
      return StubCode::SmiEqualInlineCache().raw();
    default:
      return Code::null();
  }
}
#else
static void TryFastPathSmiOp(FlowGraphCompiler* compiler,
                             ICData* call_ic_data,
                             Token::Kind op_kind) {
  if (!FLAG_two_args_smi_icd) {
    return;
  }
  switch (op_kind) {
    case Token::kADD:
      if (call_ic_data->AddSmiSmiCheckForFastSmiStubs()) {
        __ AddTOS();
      }
      break;
    case Token::kSUB:
      if (call_ic_data->AddSmiSmiCheckForFastSmiStubs()) {
        __ SubTOS();
      }
      break;
    case Token::kEQ:
      if (call_ic_data->AddSmiSmiCheckForFastSmiStubs()) {
        __ EqualTOS();
      }
      break;
    case Token::kLT:
      if (call_ic_data->AddSmiSmiCheckForFastSmiStubs()) {
        __ LessThanTOS();
      }
      break;
    case Token::kGT:
      if (call_ic_data->AddSmiSmiCheckForFastSmiStubs()) {
        __ GreaterThanTOS();
      }
      break;
    case Token::kBIT_AND:
      if (call_ic_data->AddSmiSmiCheckForFastSmiStubs()) {
        __ BitAndTOS();
      }
      break;
    case Token::kBIT_OR:
      if (call_ic_data->AddSmiSmiCheckForFastSmiStubs()) {
        __ BitOrTOS();
      }
      break;
    case Token::kMUL:
      if (call_ic_data->AddSmiSmiCheckForFastSmiStubs()) {
        __ MulTOS();
      }
      break;
    default:
      break;
  }
}
#endif

void InstanceCallInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  Zone* zone = compiler->zone();
  const ICData* call_ic_data = NULL;
  if (!FLAG_propagate_ic_data || !compiler->is_optimizing() ||
      (ic_data() == NULL)) {
    const Array& arguments_descriptor =
        Array::Handle(zone, GetArgumentsDescriptor());

    AbstractType& receivers_static_type = AbstractType::Handle(zone);
    if (receivers_static_type_ != nullptr) {
      receivers_static_type = receivers_static_type_->raw();
    }

    call_ic_data = compiler->GetOrAddInstanceCallICData(
        deopt_id(), function_name(), arguments_descriptor,
        checked_argument_count(), receivers_static_type);
  } else {
    call_ic_data = &ICData::ZoneHandle(zone, ic_data()->raw());
  }

#if !defined(TARGET_ARCH_DBC)
  if ((compiler->is_optimizing() || compiler->function().HasBytecode()) &&
      HasICData()) {
    ASSERT(HasICData());
    if (compiler->is_optimizing() && (ic_data()->NumberOfUsedChecks() > 0)) {
      const ICData& unary_ic_data =
          ICData::ZoneHandle(zone, ic_data()->AsUnaryClassChecks());
      compiler->GenerateInstanceCall(deopt_id(), token_pos(), locs(),
                                     unary_ic_data, entry_kind());
    } else {
      // Call was not visited yet, use original ICData in order to populate it.
      compiler->GenerateInstanceCall(deopt_id(), token_pos(), locs(),
                                     *call_ic_data, entry_kind());
    }
  } else {
    // Unoptimized code.
    compiler->AddCurrentDescriptor(RawPcDescriptors::kRewind, deopt_id(),
                                   token_pos());
    bool is_smi_two_args_op = false;
    const Code& stub =
        Code::ZoneHandle(TwoArgsSmiOpInlineCacheEntry(token_kind()));
    if (!stub.IsNull()) {
      // We have a dedicated inline cache stub for this operation, add an
      // an initial Smi/Smi check with count 0.
      is_smi_two_args_op = call_ic_data->AddSmiSmiCheckForFastSmiStubs();
    }
    if (is_smi_two_args_op) {
      ASSERT(ArgumentCount() == 2);
      compiler->EmitInstanceCallJIT(stub, *call_ic_data, deopt_id(),
                                    token_pos(), locs(), entry_kind());
    } else {
      compiler->GenerateInstanceCall(deopt_id(), token_pos(), locs(),
                                     *call_ic_data);
    }
  }
#else
  ICData* original_ic_data = &ICData::ZoneHandle(call_ic_data->Original());

  // Emit smi fast path instruction. If fast-path succeeds it skips the next
  // instruction otherwise it falls through. Only attempt in unoptimized code
  // because TryFastPathSmiOp will update original_ic_data.
  if (!compiler->is_optimizing()) {
    TryFastPathSmiOp(compiler, original_ic_data, token_kind());
  }

  const intptr_t call_ic_data_kidx = __ AddConstant(*original_ic_data);
  switch (original_ic_data->NumArgsTested()) {
    case 1:
      if (compiler->is_optimizing()) {
        __ InstanceCall1Opt(ArgumentCount(), call_ic_data_kidx);
      } else {
        __ InstanceCall1(ArgumentCount(), call_ic_data_kidx);
      }
      break;
    case 2:
      if (compiler->is_optimizing()) {
        __ InstanceCall2Opt(ArgumentCount(), call_ic_data_kidx);
      } else {
        __ InstanceCall2(ArgumentCount(), call_ic_data_kidx);
      }
      break;
    default:
      UNIMPLEMENTED();
      break;
  }
  compiler->AddCurrentDescriptor(RawPcDescriptors::kRewind, deopt_id(),
                                 token_pos());
  compiler->AddCurrentDescriptor(RawPcDescriptors::kIcCall, deopt_id(),
                                 token_pos());
  compiler->RecordAfterCall(this, FlowGraphCompiler::kHasResult);

  if (compiler->is_optimizing()) {
    __ PopLocal(locs()->out(0).reg());
  }
#endif  // !defined(TARGET_ARCH_DBC)
}

bool InstanceCallInstr::MatchesCoreName(const String& name) {
  return Library::IsPrivateCoreLibName(function_name(), name);
}

RawFunction* InstanceCallInstr::ResolveForReceiverClass(
    const Class& cls,
    bool allow_add /* = true */) {
  const Array& args_desc_array = Array::Handle(GetArgumentsDescriptor());
  ArgumentsDescriptor args_desc(args_desc_array);
  return Resolver::ResolveDynamicForReceiverClass(cls, function_name(),
                                                  args_desc, allow_add);
}

bool CallTargets::HasSingleRecognizedTarget() const {
  if (!HasSingleTarget()) return false;
  return MethodRecognizer::RecognizeKind(FirstTarget()) !=
         MethodRecognizer::kUnknown;
}

bool CallTargets::HasSingleTarget() const {
  ASSERT(length() != 0);
  for (int i = 0; i < length(); i++) {
    if (TargetAt(i)->target->raw() != TargetAt(0)->target->raw()) return false;
  }
  return true;
}

const Function& CallTargets::FirstTarget() const {
  ASSERT(length() != 0);
  ASSERT(TargetAt(0)->target->IsZoneHandle());
  return *TargetAt(0)->target;
}

const Function& CallTargets::MostPopularTarget() const {
  ASSERT(length() != 0);
  ASSERT(TargetAt(0)->target->IsZoneHandle());
  for (int i = 1; i < length(); i++) {
    ASSERT(TargetAt(i)->count <= TargetAt(0)->count);
  }
  return *TargetAt(0)->target;
}

intptr_t CallTargets::AggregateCallCount() const {
  intptr_t sum = 0;
  for (int i = 0; i < length(); i++) {
    sum += TargetAt(i)->count;
  }
  return sum;
}

bool PolymorphicInstanceCallInstr::HasOnlyDispatcherOrImplicitAccessorTargets()
    const {
  const intptr_t len = targets_.length();
  Function& target = Function::Handle();
  for (intptr_t i = 0; i < len; i++) {
    target = targets_.TargetAt(i)->target->raw();
    if (!target.IsDispatcherOrImplicitAccessor()) {
      return false;
    }
  }
  return true;
}

intptr_t PolymorphicInstanceCallInstr::CallCount() const {
  return targets().AggregateCallCount();
}

// DBC does not support optimizing compiler and thus doesn't emit
// PolymorphicInstanceCallInstr.
#if !defined(TARGET_ARCH_DBC)
void PolymorphicInstanceCallInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  ArgumentsInfo args_info(instance_call()->type_args_len(),
                          instance_call()->ArgumentCount(),
                          instance_call()->argument_names());
  compiler->EmitPolymorphicInstanceCall(
      targets_, *instance_call(), args_info, deopt_id(),
      instance_call()->token_pos(), locs(), complete(), total_call_count());
}
#endif

RawType* PolymorphicInstanceCallInstr::ComputeRuntimeType(
    const CallTargets& targets) {
  bool is_string = true;
  bool is_integer = true;
  bool is_double = true;

  const intptr_t num_checks = targets.length();
  for (intptr_t i = 0; i < num_checks; i++) {
    ASSERT(targets.TargetAt(i)->target->raw() ==
           targets.TargetAt(0)->target->raw());
    const intptr_t start = targets[i].cid_start;
    const intptr_t end = targets[i].cid_end;
    for (intptr_t cid = start; cid <= end; cid++) {
      is_string = is_string && RawObject::IsStringClassId(cid);
      is_integer = is_integer && RawObject::IsIntegerClassId(cid);
      is_double = is_double && (cid == kDoubleCid);
    }
  }

  if (is_string) {
    ASSERT(!is_integer);
    ASSERT(!is_double);
    return Type::StringType();
  } else if (is_integer) {
    ASSERT(!is_double);
    return Type::IntType();
  } else if (is_double) {
    return Type::Double();
  }

  return Type::null();
}

Definition* InstanceCallInstr::Canonicalize(FlowGraph* flow_graph) {
  const intptr_t receiver_cid = Receiver()->Type()->ToCid();

  // We could turn cold call sites for known receiver cids into a StaticCall.
  // However, that keeps the ICData of the InstanceCall from being updated.
  // This is fine if there is no later deoptimization, but if there is, then
  // the InstanceCall with the updated ICData for this receiver may then be
  // better optimized by the compiler.
  //
  // TODO(dartbug.com/37291): Allow this optimization, but accumulate affected
  // InstanceCallInstrs and the corresponding reciever cids during compilation.
  // After compilation, add receiver checks to the ICData for those call sites.
  if (ic_data()->NumberOfUsedChecks() == 0) return this;

  const CallTargets* new_target =
      FlowGraphCompiler::ResolveCallTargetsForReceiverCid(
          receiver_cid,
          String::Handle(flow_graph->zone(), ic_data()->target_name()),
          Array::Handle(flow_graph->zone(), ic_data()->arguments_descriptor()));
  if (new_target == NULL) {
    // No specialization.
    return this;
  }

  ASSERT(new_target->HasSingleTarget());
  const Function& target = new_target->FirstTarget();
  StaticCallInstr* specialized = StaticCallInstr::FromCall(
      flow_graph->zone(), this, target, new_target->AggregateCallCount());
  flow_graph->InsertBefore(this, specialized, env(), FlowGraph::kValue);
  return specialized;
}

Definition* PolymorphicInstanceCallInstr::Canonicalize(FlowGraph* flow_graph) {
  if (!IsSureToCallSingleRecognizedTarget()) {
    return this;
  }

  const Function& target = targets().FirstTarget();
  if (target.recognized_kind() == MethodRecognizer::kObjectRuntimeType) {
    const AbstractType& type =
        AbstractType::Handle(ComputeRuntimeType(targets_));
    if (!type.IsNull()) {
      return flow_graph->GetConstant(type);
    }
  }

  return this;
}

bool PolymorphicInstanceCallInstr::IsSureToCallSingleRecognizedTarget() const {
  if (FLAG_precompiled_mode && !complete()) return false;
  return targets_.HasSingleRecognizedTarget();
}

bool StaticCallInstr::InitResultType(Zone* zone) {
  const intptr_t list_cid = FactoryRecognizer::GetResultCidOfListFactory(
      zone, function(), ArgumentCount());
  if (list_cid != kDynamicCid) {
    SetResultType(zone, CompileType::FromCid(list_cid));
    set_is_known_list_constructor(true);
    return true;
  } else if (function().has_pragma()) {
    const intptr_t recognized_cid =
        MethodRecognizer::ResultCidFromPragma(function());
    if (recognized_cid != kDynamicCid) {
      SetResultType(zone, CompileType::FromCid(recognized_cid));
      return true;
    }
  }
  return false;
}

Definition* StaticCallInstr::Canonicalize(FlowGraph* flow_graph) {
  if (!FLAG_precompiled_mode) {
    return this;
  }

  if (function().recognized_kind() == MethodRecognizer::kObjectRuntimeType) {
    if (input_use_list() == NULL) {
      // This function has only environment uses. In precompiled mode it is
      // fine to remove it - because we will never deoptimize.
      return flow_graph->constant_dead();
    }
  }

  return this;
}

LocationSummary* StaticCallInstr::MakeLocationSummary(Zone* zone,
                                                      bool optimizing) const {
  return MakeCallSummary(zone);
}

void StaticCallInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  Zone* zone = compiler->zone();
  const ICData* call_ic_data = NULL;
  if (!FLAG_propagate_ic_data || !compiler->is_optimizing() ||
      (ic_data() == NULL)) {
    const Array& arguments_descriptor =
        Array::Handle(zone, GetArgumentsDescriptor());
    const int num_args_checked =
        MethodRecognizer::NumArgsCheckedForStaticCall(function());
    call_ic_data = compiler->GetOrAddStaticCallICData(
        deopt_id(), function(), arguments_descriptor, num_args_checked,
        rebind_rule_);
  } else {
    call_ic_data = &ICData::ZoneHandle(ic_data()->raw());
  }

#if !defined(TARGET_ARCH_DBC)
  ArgumentsInfo args_info(type_args_len(), ArgumentCount(), argument_names());
  compiler->GenerateStaticCall(deopt_id(), token_pos(), function(), args_info,
                               locs(), *call_ic_data, rebind_rule_,
                               entry_kind());
  if (function().IsFactory()) {
    TypeUsageInfo* type_usage_info = compiler->thread()->type_usage_info();
    if (type_usage_info != nullptr) {
      const Class& klass = Class::Handle(function().Owner());
      RegisterTypeArgumentsUse(compiler->function(), type_usage_info, klass,
                               ArgumentAt(0));
    }
  }
#else
  const Array& arguments_descriptor = Array::Handle(
      zone, (ic_data() == NULL) ? GetArgumentsDescriptor()
                                : ic_data()->arguments_descriptor());
  const intptr_t argdesc_kidx = __ AddConstant(arguments_descriptor);

  compiler->AddCurrentDescriptor(RawPcDescriptors::kRewind, deopt_id(),
                                 token_pos());
  if (compiler->is_optimizing()) {
    __ PushConstant(function());
    __ StaticCall(ArgumentCount(), argdesc_kidx);
    compiler->AddCurrentDescriptor(RawPcDescriptors::kOther, deopt_id(),
                                   token_pos());
    compiler->RecordAfterCall(this, FlowGraphCompiler::kHasResult);
    __ PopLocal(locs()->out(0).reg());
  } else {
    const intptr_t ic_data_kidx = __ AddConstant(*call_ic_data);
    __ PushConstant(ic_data_kidx);
    __ IndirectStaticCall(ArgumentCount(), argdesc_kidx);
    compiler->AddCurrentDescriptor(RawPcDescriptors::kUnoptStaticCall,
                                   deopt_id(), token_pos());
    compiler->RecordAfterCall(this, FlowGraphCompiler::kHasResult);
  }
#endif  // !defined(TARGET_ARCH_DBC)
}

intptr_t AssertAssignableInstr::statistics_tag() const {
  switch (kind_) {
    case kParameterCheck:
      return CombinedCodeStatistics::kTagAssertAssignableParameterCheck;
    case kInsertedByFrontend:
      return CombinedCodeStatistics::kTagAssertAssignableInsertedByFrontend;
    case kFromSource:
      return CombinedCodeStatistics::kTagAssertAssignableFromSource;
    case kUnknown:
      break;
  }

  return tag();
}

void AssertAssignableInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  compiler->GenerateAssertAssignable(token_pos(), deopt_id(), dst_type(),
                                     dst_name(), locs());

// DBC does not use LocationSummaries in the same way as other architectures.
#if !defined(TARGET_ARCH_DBC)
  ASSERT(locs()->in(0).reg() == locs()->out(0).reg());
#endif  // !defined(TARGET_ARCH_DBC)
}

void AssertSubtypeInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
#if !defined(TARGET_ARCH_DBC)
  ASSERT(sub_type().IsFinalized());
  ASSERT(super_type().IsFinalized());

  __ PushRegister(locs()->in(0).reg());
  __ PushRegister(locs()->in(1).reg());
  __ PushObject(sub_type());
  __ PushObject(super_type());
  __ PushObject(dst_name());

  compiler->GenerateRuntimeCall(token_pos(), deopt_id(),
                                kSubtypeCheckRuntimeEntry, 5, locs());

  __ Drop(5);
#else
  if (compiler->is_optimizing()) {
    __ Push(locs()->in(0).reg());  // Instantiator type arguments.
    __ Push(locs()->in(1).reg());  // Function type arguments.
  } else {
    // The 2 inputs are already on the expression stack.
  }
  __ PushConstant(sub_type());
  __ PushConstant(super_type());
  __ PushConstant(dst_name());
  __ AssertSubtype();

#endif
}

LocationSummary* DeoptimizeInstr::MakeLocationSummary(Zone* zone,
                                                      bool opt) const {
  return new (zone) LocationSummary(zone, 0, 0, LocationSummary::kNoCall);
}

void DeoptimizeInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
#if !defined(TARGET_ARCH_DBC)
  __ Jump(compiler->AddDeoptStub(deopt_id(), deopt_reason_));
#else
  compiler->EmitDeopt(deopt_id(), deopt_reason_);
#endif
}

#if !defined(TARGET_ARCH_DBC)

void CheckClassInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  compiler::Label* deopt =
      compiler->AddDeoptStub(deopt_id(), ICData::kDeoptCheckClass,
                             licm_hoisted_ ? ICData::kHoisted : 0);
  if (IsNullCheck()) {
    EmitNullCheck(compiler, deopt);
    return;
  }

  ASSERT(!cids_.IsMonomorphic() || !cids_.HasClassId(kSmiCid));
  Register value = locs()->in(0).reg();
  Register temp = locs()->temp(0).reg();
  compiler::Label is_ok;

  __ BranchIfSmi(value, cids_.HasClassId(kSmiCid) ? &is_ok : deopt);

  __ LoadClassId(temp, value);

  if (IsBitTest()) {
    intptr_t min = cids_.ComputeLowestCid();
    intptr_t max = cids_.ComputeHighestCid();
    EmitBitTest(compiler, min, max, ComputeCidMask(), deopt);
  } else {
    const intptr_t num_checks = cids_.length();
    const bool use_near_jump = num_checks < 5;
    int bias = 0;
    for (intptr_t i = 0; i < num_checks; i++) {
      intptr_t cid_start = cids_[i].cid_start;
      intptr_t cid_end = cids_[i].cid_end;
      if (cid_start == kSmiCid && cid_end == kSmiCid) {
        continue;  // We already handled Smi above.
      }
      if (cid_start == kSmiCid) cid_start++;
      if (cid_end == kSmiCid) cid_end--;
      const bool is_last =
          (i == num_checks - 1) ||
          (i == num_checks - 2 && cids_[i + 1].cid_start == kSmiCid &&
           cids_[i + 1].cid_end == kSmiCid);
      bias = EmitCheckCid(compiler, bias, cid_start, cid_end, is_last, &is_ok,
                          deopt, use_near_jump);
    }
  }
  __ Bind(&is_ok);
}

LocationSummary* GenericCheckBoundInstr::MakeLocationSummary(Zone* zone,
                                                             bool opt) const {
  const intptr_t kNumInputs = 2;
  const intptr_t kNumTemps = 0;
  LocationSummary* locs = new (zone) LocationSummary(
      zone, kNumInputs, kNumTemps, LocationSummary::kCallOnSlowPath);
  locs->set_in(kLengthPos, Location::RequiresRegister());
  locs->set_in(kIndexPos, Location::RequiresRegister());
  return locs;
}

class RangeErrorSlowPath : public ThrowErrorSlowPathCode {
 public:
  static const intptr_t kNumberOfArguments = 2;

  RangeErrorSlowPath(GenericCheckBoundInstr* instruction, intptr_t try_index)
      : ThrowErrorSlowPathCode(instruction,
                               kRangeErrorRuntimeEntry,
                               kNumberOfArguments,
                               try_index) {}

  virtual const char* name() { return "check bound"; }
};

void GenericCheckBoundInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  RangeErrorSlowPath* slow_path =
      new RangeErrorSlowPath(this, compiler->CurrentTryIndex());
  compiler->AddSlowPathCode(slow_path);
  Location length_loc = locs()->in(kLengthPos);
  Location index_loc = locs()->in(kIndexPos);
  Register length = length_loc.reg();
  Register index = index_loc.reg();
  const intptr_t index_cid = this->index()->Type()->ToCid();
  if (index_cid != kSmiCid) {
    __ BranchIfNotSmi(index, slow_path->entry_label());
  }
  __ CompareRegisters(index, length);
  __ BranchIf(UNSIGNED_GREATER_EQUAL, slow_path->entry_label());
}

LocationSummary* CheckNullInstr::MakeLocationSummary(Zone* zone,
                                                     bool opt) const {
  const intptr_t kNumInputs = 1;
  const intptr_t kNumTemps = 0;
  LocationSummary* locs = new (zone) LocationSummary(
      zone, kNumInputs, kNumTemps,
      UseSharedSlowPathStub(opt) ? LocationSummary::kCallOnSharedSlowPath
                                 : LocationSummary::kCallOnSlowPath);
  locs->set_in(0, Location::RequiresRegister());
  return locs;
}

#endif  // !defined(TARGET_ARCH_DBC)

void CheckNullInstr::AddMetadataForRuntimeCall(CheckNullInstr* check_null,
                                               FlowGraphCompiler* compiler) {
  const String& function_name = check_null->function_name();
  const intptr_t name_index =
      compiler->assembler()->object_pool_builder().FindObject(function_name);
  compiler->AddNullCheck(compiler->assembler()->CodeSize(),
                         check_null->token_pos(), name_index);
}

#if !defined(TARGET_ARCH_DBC)

void UnboxInstr::EmitLoadFromBoxWithDeopt(FlowGraphCompiler* compiler) {
  const intptr_t box_cid = BoxCid();
  const Register box = locs()->in(0).reg();
  const Register temp =
      (locs()->temp_count() > 0) ? locs()->temp(0).reg() : kNoRegister;
  compiler::Label* deopt =
      compiler->AddDeoptStub(GetDeoptId(), ICData::kDeoptUnbox);
  compiler::Label is_smi;

  if ((value()->Type()->ToNullableCid() == box_cid) &&
      value()->Type()->is_nullable()) {
    __ CompareObject(box, Object::null_object());
    __ BranchIf(EQUAL, deopt);
  } else {
    __ BranchIfSmi(box, CanConvertSmi() ? &is_smi : deopt);
    __ CompareClassId(box, box_cid, temp);
    __ BranchIf(NOT_EQUAL, deopt);
  }

  EmitLoadFromBox(compiler);

  if (is_smi.IsLinked()) {
    compiler::Label done;
    __ Jump(&done);
    __ Bind(&is_smi);
    EmitSmiConversion(compiler);
    __ Bind(&done);
  }
}

void UnboxInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  if (speculative_mode() == kNotSpeculative) {
    switch (representation()) {
      case kUnboxedDouble:
      case kUnboxedFloat:
        EmitLoadFromBox(compiler);
        break;

      case kUnboxedInt32:
        EmitLoadInt32FromBoxOrSmi(compiler);
        break;

      case kUnboxedInt64: {
        if (value()->Type()->ToCid() == kSmiCid) {
          // Smi -> int64 conversion is more efficient than
          // handling arbitrary smi/mint.
          EmitSmiConversion(compiler);
        } else {
          EmitLoadInt64FromBoxOrSmi(compiler);
        }
        break;
      }
      default:
        UNREACHABLE();
        break;
    }
  } else {
    ASSERT(speculative_mode() == kGuardInputs);
    const intptr_t value_cid = value()->Type()->ToCid();
    const intptr_t box_cid = BoxCid();

    if (value_cid == box_cid) {
      EmitLoadFromBox(compiler);
    } else if (CanConvertSmi() && (value_cid == kSmiCid)) {
      EmitSmiConversion(compiler);
    } else {
      ASSERT(CanDeoptimize());
      EmitLoadFromBoxWithDeopt(compiler);
    }
  }
}

#endif  // !defined(TARGET_ARCH_DBC)

Environment* Environment::From(Zone* zone,
                               const GrowableArray<Definition*>& definitions,
                               intptr_t fixed_parameter_count,
                               const ParsedFunction& parsed_function) {
  Environment* env = new (zone) Environment(
      definitions.length(), fixed_parameter_count, parsed_function, NULL);
  for (intptr_t i = 0; i < definitions.length(); ++i) {
    env->values_.Add(new (zone) Value(definitions[i]));
  }
  return env;
}

void Environment::PushValue(Value* value) {
  values_.Add(value);
}

Environment* Environment::DeepCopy(Zone* zone, intptr_t length) const {
  ASSERT(length <= values_.length());
  Environment* copy =
      new (zone) Environment(length, fixed_parameter_count_, parsed_function_,
                             (outer_ == NULL) ? NULL : outer_->DeepCopy(zone));
  copy->deopt_id_ = this->deopt_id_;
  if (locations_ != NULL) {
    Location* new_locations = zone->Alloc<Location>(length);
    copy->set_locations(new_locations);
  }
  for (intptr_t i = 0; i < length; ++i) {
    copy->values_.Add(values_[i]->Copy(zone));
    if (locations_ != NULL) {
      copy->locations_[i] = locations_[i].Copy();
    }
  }
  return copy;
}

// Copies the environment and updates the environment use lists.
void Environment::DeepCopyTo(Zone* zone, Instruction* instr) const {
  for (Environment::DeepIterator it(instr->env()); !it.Done(); it.Advance()) {
    it.CurrentValue()->RemoveFromUseList();
  }

  Environment* copy = DeepCopy(zone);
  instr->SetEnvironment(copy);
  for (Environment::DeepIterator it(copy); !it.Done(); it.Advance()) {
    Value* value = it.CurrentValue();
    value->definition()->AddEnvUse(value);
  }
}

void Environment::DeepCopyAfterTo(Zone* zone,
                                  Instruction* instr,
                                  intptr_t argc,
                                  Definition* dead,
                                  Definition* result) const {
  for (Environment::DeepIterator it(instr->env()); !it.Done(); it.Advance()) {
    it.CurrentValue()->RemoveFromUseList();
  }

  Environment* copy = DeepCopy(zone, values_.length() - argc);
  for (intptr_t i = 0; i < argc; i++) {
    copy->values_.Add(new (zone) Value(dead));
  }
  copy->values_.Add(new (zone) Value(result));

  instr->SetEnvironment(copy);
  for (Environment::DeepIterator it(copy); !it.Done(); it.Advance()) {
    Value* value = it.CurrentValue();
    value->definition()->AddEnvUse(value);
  }
}

// Copies the environment as outer on an inlined instruction and updates the
// environment use lists.
void Environment::DeepCopyToOuter(Zone* zone,
                                  Instruction* instr,
                                  intptr_t outer_deopt_id) const {
  // Create a deep copy removing caller arguments from the environment.
  ASSERT(this != NULL);
  ASSERT(instr->env()->outer() == NULL);
  intptr_t argument_count = instr->env()->fixed_parameter_count();
  Environment* copy = DeepCopy(zone, values_.length() - argument_count);
  copy->deopt_id_ = outer_deopt_id;
  instr->env()->outer_ = copy;
  intptr_t use_index = instr->env()->Length();  // Start index after inner.
  for (Environment::DeepIterator it(copy); !it.Done(); it.Advance()) {
    Value* value = it.CurrentValue();
    value->set_instruction(instr);
    value->set_use_index(use_index++);
    value->definition()->AddEnvUse(value);
  }
}

ComparisonInstr* DoubleTestOpInstr::CopyWithNewOperands(Value* new_left,
                                                        Value* new_right) {
  UNREACHABLE();
  return NULL;
}

ComparisonInstr* EqualityCompareInstr::CopyWithNewOperands(Value* new_left,
                                                           Value* new_right) {
  return new EqualityCompareInstr(token_pos(), kind(), new_left, new_right,
                                  operation_cid(), deopt_id());
}

ComparisonInstr* RelationalOpInstr::CopyWithNewOperands(Value* new_left,
                                                        Value* new_right) {
  return new RelationalOpInstr(token_pos(), kind(), new_left, new_right,
                               operation_cid(), deopt_id(), speculative_mode());
}

ComparisonInstr* StrictCompareInstr::CopyWithNewOperands(Value* new_left,
                                                         Value* new_right) {
  return new StrictCompareInstr(token_pos(), kind(), new_left, new_right,
                                needs_number_check(), DeoptId::kNone);
}

ComparisonInstr* TestSmiInstr::CopyWithNewOperands(Value* new_left,
                                                   Value* new_right) {
  return new TestSmiInstr(token_pos(), kind(), new_left, new_right);
}

ComparisonInstr* TestCidsInstr::CopyWithNewOperands(Value* new_left,
                                                    Value* new_right) {
  return new TestCidsInstr(token_pos(), kind(), new_left, cid_results(),
                           deopt_id());
}

bool TestCidsInstr::AttributesEqual(Instruction* other) const {
  TestCidsInstr* other_instr = other->AsTestCids();
  if (!ComparisonInstr::AttributesEqual(other)) {
    return false;
  }
  if (cid_results().length() != other_instr->cid_results().length()) {
    return false;
  }
  for (intptr_t i = 0; i < cid_results().length(); i++) {
    if (cid_results()[i] != other_instr->cid_results()[i]) {
      return false;
    }
  }
  return true;
}

#if !defined(TARGET_ARCH_DBC)
static bool BindsToSmiConstant(Value* value) {
  return value->BindsToConstant() && value->BoundConstant().IsSmi();
}
#endif

bool IfThenElseInstr::Supports(ComparisonInstr* comparison,
                               Value* v1,
                               Value* v2) {
#if !defined(TARGET_ARCH_DBC)
  bool is_smi_result = BindsToSmiConstant(v1) && BindsToSmiConstant(v2);
  if (comparison->IsStrictCompare()) {
    // Strict comparison with number checks calls a stub and is not supported
    // by if-conversion.
    return is_smi_result &&
           !comparison->AsStrictCompare()->needs_number_check();
  }
  if (comparison->operation_cid() != kSmiCid) {
    // Non-smi comparisons are not supported by if-conversion.
    return false;
  }
  return is_smi_result;
#else
  return false;
#endif  // !defined(TARGET_ARCH_DBC)
}

bool PhiInstr::IsRedundant() const {
  ASSERT(InputCount() > 1);
  Definition* first = InputAt(0)->definition();
  for (intptr_t i = 1; i < InputCount(); ++i) {
    Definition* def = InputAt(i)->definition();
    if (def != first) return false;
  }
  return true;
}

Instruction* CheckConditionInstr::Canonicalize(FlowGraph* graph) {
  if (StrictCompareInstr* strict_compare = comparison()->AsStrictCompare()) {
    if ((InputAt(0)->definition()->OriginalDefinition() ==
         InputAt(1)->definition()->OriginalDefinition()) &&
        strict_compare->kind() == Token::kEQ_STRICT) {
      return nullptr;
    }
  }
  return this;
}

bool CheckArrayBoundInstr::IsFixedLengthArrayType(intptr_t cid) {
  return LoadFieldInstr::IsFixedLengthArrayCid(cid);
}

Definition* CheckArrayBoundInstr::Canonicalize(FlowGraph* flow_graph) {
  return IsRedundant(RangeBoundary::FromDefinition(length()->definition()))
             ? index()->definition()
             : this;
}

intptr_t CheckArrayBoundInstr::LengthOffsetFor(intptr_t class_id) {
  if (RawObject::IsTypedDataClassId(class_id) ||
      RawObject::IsTypedDataViewClassId(class_id) ||
      RawObject::IsExternalTypedDataClassId(class_id)) {
    return compiler::target::TypedDataBase::length_offset();
  }

  switch (class_id) {
    case kGrowableObjectArrayCid:
      return compiler::target::GrowableObjectArray::length_offset();
    case kOneByteStringCid:
    case kTwoByteStringCid:
      return compiler::target::String::length_offset();
    case kArrayCid:
    case kImmutableArrayCid:
      return compiler::target::Array::length_offset();
    default:
      UNREACHABLE();
      return -1;
  }
}

const Function& StringInterpolateInstr::CallFunction() const {
  if (function_.IsNull()) {
    const int kTypeArgsLen = 0;
    const int kNumberOfArguments = 1;
    const Array& kNoArgumentNames = Object::null_array();
    const Class& cls =
        Class::Handle(Library::LookupCoreClass(Symbols::StringBase()));
    ASSERT(!cls.IsNull());
    function_ = Resolver::ResolveStatic(
        cls, Library::PrivateCoreLibName(Symbols::Interpolate()), kTypeArgsLen,
        kNumberOfArguments, kNoArgumentNames);
  }
  ASSERT(!function_.IsNull());
  return function_;
}

// Replace StringInterpolateInstr with a constant string if all inputs are
// constant of [string, number, boolean, null].
// Leave the CreateArrayInstr and StoreIndexedInstr in the stream in case
// deoptimization occurs.
Definition* StringInterpolateInstr::Canonicalize(FlowGraph* flow_graph) {
  // The following graph structure is generated by the graph builder:
  //   v2 <- CreateArray(v0)
  //   StoreIndexed(v2, v3, v4)   -- v3:constant index, v4: value.
  //   ..
  //   v8 <- StringInterpolate(v2)

  // Don't compile-time fold when optimizing the interpolation function itself.
  if (flow_graph->function().raw() == CallFunction().raw()) {
    return this;
  }

  CreateArrayInstr* create_array = value()->definition()->AsCreateArray();
  ASSERT(create_array != NULL);
  // Check if the string interpolation has only constant inputs.
  Value* num_elements = create_array->num_elements();
  if (!num_elements->BindsToConstant() ||
      !num_elements->BoundConstant().IsSmi()) {
    return this;
  }
  const intptr_t length = Smi::Cast(num_elements->BoundConstant()).Value();
  Thread* thread = Thread::Current();
  Zone* zone = thread->zone();
  GrowableHandlePtrArray<const String> pieces(zone, length);
  for (intptr_t i = 0; i < length; i++) {
    pieces.Add(Object::null_string());
  }

  for (Value::Iterator it(create_array->input_use_list()); !it.Done();
       it.Advance()) {
    Instruction* curr = it.Current()->instruction();
    if (curr == this) continue;

    StoreIndexedInstr* store = curr->AsStoreIndexed();
    if (store == nullptr || !store->index()->BindsToConstant() ||
        !store->index()->BoundConstant().IsSmi()) {
      return this;
    }
    intptr_t store_index = Smi::Cast(store->index()->BoundConstant()).Value();
    ASSERT(store_index < length);
    ASSERT(store != NULL);
    if (store->value()->definition()->IsConstant()) {
      ASSERT(store->index()->BindsToConstant());
      const Object& obj = store->value()->definition()->AsConstant()->value();
      // TODO(srdjan): Verify if any other types should be converted as well.
      if (obj.IsString()) {
        pieces.SetAt(store_index, String::Cast(obj));
      } else if (obj.IsSmi()) {
        const char* cstr = obj.ToCString();
        pieces.SetAt(store_index,
                     String::Handle(zone, String::New(cstr, Heap::kOld)));
      } else if (obj.IsBool()) {
        pieces.SetAt(store_index, Bool::Cast(obj).value() ? Symbols::True()
                                                          : Symbols::False());
      } else if (obj.IsNull()) {
        pieces.SetAt(store_index, Symbols::null());
      } else {
        return this;
      }
    } else {
      return this;
    }
  }

  const String& concatenated =
      String::ZoneHandle(zone, Symbols::FromConcatAll(thread, pieces));
  return flow_graph->GetConstant(concatenated);
}

static AlignmentType StrengthenAlignment(intptr_t cid,
                                         AlignmentType alignment) {
  switch (cid) {
    case kTypedDataInt8ArrayCid:
    case kTypedDataUint8ArrayCid:
    case kTypedDataUint8ClampedArrayCid:
    case kExternalTypedDataUint8ArrayCid:
    case kExternalTypedDataUint8ClampedArrayCid:
    case kOneByteStringCid:
    case kExternalOneByteStringCid:
      // Don't need to worry about alignment for accessing bytes.
      return kAlignedAccess;
    case kTypedDataFloat64x2ArrayCid:
    case kTypedDataInt32x4ArrayCid:
    case kTypedDataFloat32x4ArrayCid:
      // TODO(rmacnak): Investigate alignment requirements of floating point
      // loads.
      return kAlignedAccess;
  }

  return alignment;
}

LoadIndexedInstr::LoadIndexedInstr(Value* array,
                                   Value* index,
                                   intptr_t index_scale,
                                   intptr_t class_id,
                                   AlignmentType alignment,
                                   intptr_t deopt_id,
                                   TokenPosition token_pos,
                                   CompileType* result_type)
    : TemplateDefinition(deopt_id),
      index_scale_(index_scale),
      class_id_(class_id),
      alignment_(StrengthenAlignment(class_id, alignment)),
      token_pos_(token_pos),
      result_type_(result_type) {
  SetInputAt(0, array);
  SetInputAt(1, index);
}

StoreIndexedInstr::StoreIndexedInstr(Value* array,
                                     Value* index,
                                     Value* value,
                                     StoreBarrierType emit_store_barrier,
                                     intptr_t index_scale,
                                     intptr_t class_id,
                                     AlignmentType alignment,
                                     intptr_t deopt_id,
                                     TokenPosition token_pos,
                                     SpeculativeMode speculative_mode)
    : TemplateInstruction(deopt_id),
      emit_store_barrier_(emit_store_barrier),
      index_scale_(index_scale),
      class_id_(class_id),
      alignment_(StrengthenAlignment(class_id, alignment)),
      token_pos_(token_pos),
      speculative_mode_(speculative_mode) {
  SetInputAt(kArrayPos, array);
  SetInputAt(kIndexPos, index);
  SetInputAt(kValuePos, value);
}

InvokeMathCFunctionInstr::InvokeMathCFunctionInstr(
    ZoneGrowableArray<Value*>* inputs,
    intptr_t deopt_id,
    MethodRecognizer::Kind recognized_kind,
    TokenPosition token_pos)
    : PureDefinition(deopt_id),
      inputs_(inputs),
      recognized_kind_(recognized_kind),
      token_pos_(token_pos) {
  ASSERT(inputs_->length() == ArgumentCountFor(recognized_kind_));
  for (intptr_t i = 0; i < inputs_->length(); ++i) {
    ASSERT((*inputs)[i] != NULL);
    (*inputs)[i]->set_instruction(this);
    (*inputs)[i]->set_use_index(i);
  }
}

intptr_t InvokeMathCFunctionInstr::ArgumentCountFor(
    MethodRecognizer::Kind kind) {
  switch (kind) {
    case MethodRecognizer::kDoubleTruncate:
    case MethodRecognizer::kDoubleFloor:
    case MethodRecognizer::kDoubleCeil: {
      ASSERT(!TargetCPUFeatures::double_truncate_round_supported());
      return 1;
    }
    case MethodRecognizer::kDoubleRound:
    case MethodRecognizer::kMathAtan:
    case MethodRecognizer::kMathTan:
    case MethodRecognizer::kMathAcos:
    case MethodRecognizer::kMathAsin:
    case MethodRecognizer::kMathSin:
    case MethodRecognizer::kMathCos:
      return 1;
    case MethodRecognizer::kDoubleMod:
    case MethodRecognizer::kMathDoublePow:
    case MethodRecognizer::kMathAtan2:
      return 2;
    default:
      UNREACHABLE();
  }
  return 0;
}

const RuntimeEntry& InvokeMathCFunctionInstr::TargetFunction() const {
  switch (recognized_kind_) {
    case MethodRecognizer::kDoubleTruncate:
      return kLibcTruncRuntimeEntry;
    case MethodRecognizer::kDoubleRound:
      return kLibcRoundRuntimeEntry;
    case MethodRecognizer::kDoubleFloor:
      return kLibcFloorRuntimeEntry;
    case MethodRecognizer::kDoubleCeil:
      return kLibcCeilRuntimeEntry;
    case MethodRecognizer::kMathDoublePow:
      return kLibcPowRuntimeEntry;
    case MethodRecognizer::kDoubleMod:
      return kDartModuloRuntimeEntry;
    case MethodRecognizer::kMathTan:
      return kLibcTanRuntimeEntry;
    case MethodRecognizer::kMathAsin:
      return kLibcAsinRuntimeEntry;
    case MethodRecognizer::kMathSin:
      return kLibcSinRuntimeEntry;
    case MethodRecognizer::kMathCos:
      return kLibcCosRuntimeEntry;
    case MethodRecognizer::kMathAcos:
      return kLibcAcosRuntimeEntry;
    case MethodRecognizer::kMathAtan:
      return kLibcAtanRuntimeEntry;
    case MethodRecognizer::kMathAtan2:
      return kLibcAtan2RuntimeEntry;
    default:
      UNREACHABLE();
  }
  return kLibcPowRuntimeEntry;
}

const char* MathUnaryInstr::KindToCString(MathUnaryKind kind) {
  switch (kind) {
    case kIllegal:
      return "illegal";
    case kSqrt:
      return "sqrt";
    case kDoubleSquare:
      return "double-square";
  }
  UNREACHABLE();
  return "";
}

TruncDivModInstr::TruncDivModInstr(Value* lhs, Value* rhs, intptr_t deopt_id)
    : TemplateDefinition(deopt_id) {
  SetInputAt(0, lhs);
  SetInputAt(1, rhs);
}

intptr_t TruncDivModInstr::OutputIndexOf(Token::Kind token) {
  switch (token) {
    case Token::kTRUNCDIV:
      return 0;
    case Token::kMOD:
      return 1;
    default:
      UNIMPLEMENTED();
      return -1;
  }
}

void NativeCallInstr::SetupNative() {
  if (link_lazily()) {
    // Resolution will happen during NativeEntry::LinkNativeCall.
    return;
  }

  Zone* zone = Thread::Current()->zone();
  const Class& cls = Class::Handle(zone, function().Owner());
  const Library& library = Library::Handle(zone, cls.library());

  Dart_NativeEntryResolver resolver = library.native_entry_resolver();
  bool is_bootstrap_native = Bootstrap::IsBootstrapResolver(resolver);
  set_is_bootstrap_native(is_bootstrap_native);

  const int num_params =
      NativeArguments::ParameterCountForResolution(function());
  bool auto_setup_scope = true;
  NativeFunction native_function = NativeEntry::ResolveNative(
      library, native_name(), num_params, &auto_setup_scope);
  if (native_function == NULL) {
    Report::MessageF(Report::kError, Script::Handle(function().script()),
                     function().token_pos(), Report::AtLocation,
                     "native function '%s' (%" Pd " arguments) cannot be found",
                     native_name().ToCString(), function().NumParameters());
  }
  set_is_auto_scope(auto_setup_scope);
  set_native_c_function(native_function);
}

#if !defined(TARGET_ARCH_ARM)

LocationSummary* BitCastInstr::MakeLocationSummary(Zone* zone, bool opt) const {
  UNREACHABLE();
}

void BitCastInstr::EmitNativeCode(FlowGraphCompiler* compiler) {
  UNREACHABLE();
}

#endif  // defined(TARGET_ARCH_ARM)

Representation FfiCallInstr::RequiredInputRepresentation(intptr_t idx) const {
  if (idx == TargetAddressIndex()) {
    return kUnboxedFfiIntPtr;
  } else {
    return arg_representations_[idx];
  }
}

#if !defined(TARGET_ARCH_DBC)

#define Z zone_

LocationSummary* FfiCallInstr::MakeLocationSummary(Zone* zone,
                                                   bool is_optimizing) const {
  // The temporary register needs to be callee-saved and not an argument
  // register.
  ASSERT(((1 << CallingConventions::kFirstCalleeSavedCpuReg) &
          CallingConventions::kArgumentRegisters) == 0);

#if defined(TARGET_ARCH_ARM64) || defined(TARGET_ARCH_IA32)
  constexpr intptr_t kNumTemps = 2;
#elif defined(TARGET_ARCH_ARM)
  constexpr intptr_t kNumTemps = 3;
#else
  constexpr intptr_t kNumTemps = 1;
#endif

  LocationSummary* summary = new (zone)
      LocationSummary(zone, /*num_inputs=*/InputCount(),
                      /*num_temps=*/kNumTemps, LocationSummary::kCall);

  summary->set_in(TargetAddressIndex(),
                  Location::RegisterLocation(
                      CallingConventions::kFirstNonArgumentRegister));
  summary->set_temp(0, Location::RegisterLocation(
                           CallingConventions::kSecondNonArgumentRegister));
#if defined(TARGET_ARCH_IA32) || defined(TARGET_ARCH_ARM64) ||                 \
    defined(TARGET_ARCH_ARM)
  summary->set_temp(1, Location::RegisterLocation(
                           CallingConventions::kFirstCalleeSavedCpuReg));
#endif
#if defined(TARGET_ARCH_ARM)
  summary->set_temp(2, Location::RegisterLocation(
                           CallingConventions::kSecondCalleeSavedCpuReg));
#endif
  summary->set_out(0, compiler::ffi::ResultLocation(
                          compiler::ffi::ResultRepresentation(signature_)));

  for (intptr_t i = 0, n = NativeArgCount(); i < n; ++i) {
    // Floating point values are never split: they are either in a single "FPU"
    // register or a contiguous 64-bit slot on the stack. Unboxed 64-bit integer
    // values, in contrast, can be split between any two registers on a 32-bit
    // system.
    //
    // There is an exception for iOS and Android 32-bit ARM, where
    // floating-point values are treated as integers as far as the calling
    // convention is concerned. However, the representation of these arguments
    // are set to kUnboxedInt32 or kUnboxedInt64 already, so we don't have to
    // account for that here.
    const bool is_atomic = arg_representations_[i] == kUnboxedFloat ||
                           arg_representations_[i] == kUnboxedDouble;

    // Since we have to move this input down to the stack, there's no point in
    // pinning it to any specific register.
    summary->set_in(i, UnallocateStackSlots(arg_locations_[i], is_atomic));
  }

  return summary;
}

Location FfiCallInstr::UnallocateStackSlots(Location in, bool is_atomic) {
  if (in.IsPairLocation()) {
    ASSERT(!is_atomic);
    return Location::Pair(UnallocateStackSlots(in.AsPairLocation()->At(0)),
                          UnallocateStackSlots(in.AsPairLocation()->At(1)));
  } else if (in.IsMachineRegister()) {
    return in;
  } else if (in.IsDoubleStackSlot()) {
    return is_atomic ? Location::Any()
                     : Location::Pair(Location::Any(), Location::Any());
  } else {
    ASSERT(in.IsStackSlot());
    return Location::Any();
  }
}

LocationSummary* NativeReturnInstr::MakeLocationSummary(Zone* zone,
                                                        bool opt) const {
  const intptr_t kNumInputs = 1;
  const intptr_t kNumTemps = 0;
  LocationSummary* locs = new (zone)
      LocationSummary(zone, kNumInputs, kNumTemps, LocationSummary::kNoCall);
  locs->set_in(0, result_location_);
  return locs;
}

#undef Z

#else

LocationSummary* FfiCallInstr::MakeLocationSummary(Zone* zone,
                                                   bool is_optimizing) const {
  LocationSummary* summary =
      new (zone) LocationSummary(zone, /*num_inputs=*/InputCount(),
                                 /*num_temps=*/0, LocationSummary::kCall);

  summary->set_in(
      TargetAddressIndex(),
      Location::RegisterLocation(compiler::ffi::kFunctionAddressRegister));
  for (intptr_t i = 0, n = NativeArgCount(); i < n; ++i) {
    summary->set_in(i, arg_locations_[i]);
  }
  summary->set_out(0, compiler::ffi::ResultLocation(
                          compiler::ffi::ResultHostRepresentation(signature_)));

  return summary;
}

#endif  // !defined(TARGET_ARCH_DBC)

Representation FfiCallInstr::representation() const {
#if !defined(TARGET_ARCH_DBC)
  return compiler::ffi::ResultRepresentation(signature_);
#else
  return compiler::ffi::ResultHostRepresentation(signature_);
#endif  // !defined(TARGET_ARCH_DBC)
}

// SIMD

SimdOpInstr* SimdOpInstr::CreateFromCall(Zone* zone,
                                         MethodRecognizer::Kind kind,
                                         Definition* receiver,
                                         Instruction* call,
                                         intptr_t mask /* = 0 */) {
  SimdOpInstr* op =
      new (zone) SimdOpInstr(KindForMethod(kind), call->deopt_id());
  op->SetInputAt(0, new (zone) Value(receiver));
  // Note: we are skipping receiver.
  for (intptr_t i = 1; i < op->InputCount(); i++) {
    op->SetInputAt(i, call->PushArgumentAt(i)->value()->CopyWithType(zone));
  }
  if (op->HasMask()) {
    op->set_mask(mask);
  }
  ASSERT(call->ArgumentCount() == (op->InputCount() + (op->HasMask() ? 1 : 0)));
  return op;
}

SimdOpInstr* SimdOpInstr::CreateFromFactoryCall(Zone* zone,
                                                MethodRecognizer::Kind kind,
                                                Instruction* call) {
  SimdOpInstr* op =
      new (zone) SimdOpInstr(KindForMethod(kind), call->deopt_id());
  for (intptr_t i = 0; i < op->InputCount(); i++) {
    // Note: ArgumentAt(0) is type arguments which we don't need.
    op->SetInputAt(i, call->PushArgumentAt(i + 1)->value()->CopyWithType(zone));
  }
  ASSERT(call->ArgumentCount() == (op->InputCount() + 1));
  return op;
}

SimdOpInstr::Kind SimdOpInstr::KindForOperator(intptr_t cid, Token::Kind op) {
  switch (cid) {
    case kFloat32x4Cid:
      switch (op) {
        case Token::kADD:
          return kFloat32x4Add;
        case Token::kSUB:
          return kFloat32x4Sub;
        case Token::kMUL:
          return kFloat32x4Mul;
        case Token::kDIV:
          return kFloat32x4Div;
        default:
          break;
      }
      break;

    case kFloat64x2Cid:
      switch (op) {
        case Token::kADD:
          return kFloat64x2Add;
        case Token::kSUB:
          return kFloat64x2Sub;
        case Token::kMUL:
          return kFloat64x2Mul;
        case Token::kDIV:
          return kFloat64x2Div;
        default:
          break;
      }
      break;

    case kInt32x4Cid:
      switch (op) {
        case Token::kADD:
          return kInt32x4Add;
        case Token::kSUB:
          return kInt32x4Sub;
        case Token::kBIT_AND:
          return kInt32x4BitAnd;
        case Token::kBIT_OR:
          return kInt32x4BitOr;
        case Token::kBIT_XOR:
          return kInt32x4BitXor;
        default:
          break;
      }
      break;
  }

  UNREACHABLE();
  return kIllegalSimdOp;
}

SimdOpInstr::Kind SimdOpInstr::KindForMethod(MethodRecognizer::Kind kind) {
  switch (kind) {
#define CASE_METHOD(Arity, Mask, Name, ...)                                    \
  case MethodRecognizer::k##Name:                                              \
    return k##Name;
#define CASE_BINARY_OP(Arity, Mask, Name, Args, Result)
    SIMD_OP_LIST(CASE_METHOD, CASE_BINARY_OP)
#undef CASE_METHOD
#undef CASE_BINARY_OP
    default:
      break;
  }

  FATAL1("Not a SIMD method: %s", MethodRecognizer::KindToCString(kind));
  return kIllegalSimdOp;
}

// Methods InputCount(), representation(), RequiredInputRepresentation() and
// HasMask() are using an array of SimdOpInfo structures representing all
// necessary information about the instruction.

struct SimdOpInfo {
  uint8_t arity;
  bool has_mask;
  Representation output;
  Representation inputs[4];
};

// Make representaion from type name used by SIMD_OP_LIST.
#define REP(T) (kUnboxed##T)
static const Representation kUnboxedBool = kTagged;
static const Representation kUnboxedInt8 = kUnboxedInt32;

#define ENCODE_INPUTS_0()
#define ENCODE_INPUTS_1(In0) REP(In0)
#define ENCODE_INPUTS_2(In0, In1) REP(In0), REP(In1)
#define ENCODE_INPUTS_3(In0, In1, In2) REP(In0), REP(In1), REP(In2)
#define ENCODE_INPUTS_4(In0, In1, In2, In3)                                    \
  REP(In0), REP(In1), REP(In2), REP(In3)

// Helpers for correct interpretation of the Mask field in the SIMD_OP_LIST.
#define HAS_MASK true
#define HAS__ false

// Define the metadata array.
static const SimdOpInfo simd_op_information[] = {
#define PP_APPLY(M, Args) M Args
#define CASE(Arity, Mask, Name, Args, Result)                                  \
  {Arity, HAS_##Mask, REP(Result), {PP_APPLY(ENCODE_INPUTS_##Arity, Args)}},
    SIMD_OP_LIST(CASE, CASE)
#undef CASE
#undef PP_APPLY
};

// Undef all auxiliary macros.
#undef ENCODE_INFORMATION
#undef HAS__
#undef HAS_MASK
#undef ENCODE_INPUTS_0
#undef ENCODE_INPUTS_1
#undef ENCODE_INPUTS_2
#undef ENCODE_INPUTS_3
#undef ENCODE_INPUTS_4
#undef REP

intptr_t SimdOpInstr::InputCount() const {
  return simd_op_information[kind()].arity;
}

Representation SimdOpInstr::representation() const {
  return simd_op_information[kind()].output;
}

Representation SimdOpInstr::RequiredInputRepresentation(intptr_t idx) const {
  ASSERT(0 <= idx && idx < InputCount());
  return simd_op_information[kind()].inputs[idx];
}

bool SimdOpInstr::HasMask() const {
  return simd_op_information[kind()].has_mask;
}

#undef __

}  // namespace dart

#endif  // !defined(DART_PRECOMPILED_RUNTIME)
