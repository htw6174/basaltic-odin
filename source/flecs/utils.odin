/*
 * Odin-friendly replacements for function-like macro patterns in the flecs C API.
 * Uses world-local component id slots for O(1) lookups and RTTI for optional meta registration.
 */
package flecs

import runtime "base:runtime"
import "core:fmt"
import "core:strings"

/* Odin-specific replacements for flecs function-like macro utilities */

// FIXME: the static idx doesn't survive dll reload, will return invalid id if world is not restarted immediately after reload
component_index :: proc "contextless" ($T: typeid) -> i32 {
	@(static) idx: i32
	if idx == 0 {
		idx = flecs_component_ids_index_get()
	}
	return idx
}

id :: proc "c" (world: ^World, $T: typeid) -> Id {
	return Id(flecs_component_ids_get(world, component_index(T)))
}

pair :: proc "c" (pred, obj: Id) -> Id {
	return Id(ECS_PAIR | ((u64(pred) << 32) + u64(u32(obj))))
}

component :: proc(world: ^World, $T: typeid) -> Entity {
	idx := component_index(T)
	if existing := flecs_component_ids_get_alive(world, idx); existing != 0 {
		return existing
	}

	name := strings.clone_to_cstring(type_name_from_typeid(T), context.temp_allocator)
	e := entity_init(world, &Entity_Desc{use_low_id = true, name = name, symbol = name})

	size := Size(size_of(T))
	align := Size(align_of(T))
	base := runtime.type_info_base(type_info_of(T))
	if s, ok := base.variant.(runtime.Type_Info_Struct); ok {
		// Empty structs are tags in flecs.
		if s.field_count == 0 {
			size = 0
			align = 0
		}
	}

	c := component_init(
		world,
		&Component_Desc{entity = e, type = {size = size, alignment = align, name = name}},
	)

	flecs_component_ids_set(world, idx, c)
	register_meta_from_rtti(world, c, T)
	return c
}

add :: proc "c" (world: ^World, entity: Entity, $T: typeid) {
	add_id(world, entity, id(world, T))
}

add_pair :: proc "c" (world: ^World, entity: Entity, first: Entity, second: Entity) {
	add_id(world, entity, pair(first, second))
}

set :: proc "c" (world: ^World, entity: Entity, val: ^$T) {
	set_id(world, entity, id(world, T), size_of(T), rawptr(val))
}

get :: proc "c" (world: ^World, entity: Entity, $T: typeid) -> ^T {
	return (^T)(get_id(world, entity, id(world, T)))
}

remove :: proc "c" (world: ^World, entity: Entity, $T: typeid) {
	remove_id(world, entity, id(world, T))
}

singleton_set :: proc "c" (world: ^World, val: ^$T) {
	set(world, id(world, T), val)
}

field :: proc "c" (it: ^Iter, $T: typeid, index: i8) -> [^]T {
	return ([^]T)(field_w_size(it, size_of(T), index))
}

// TODO: option to provide query terms as list of entities or expression string
system :: proc(
	world: ^World,
	callback: Iter_Action,
	phase: Entity,
	expr: cstring,
	name := #caller_expression(callback),
) -> Entity {
	// NOTE: flecs expects this array to be 0-terminated, so must be one larger than added ID count
	add_ids: [3]Id
	if phase == 0 {
		add_ids[0] = 0
	} else {
		add_ids[0] = pair(EcsDependsOn, phase)
		add_ids[1] = phase
	}

	entity_desc := Entity_Desc {
		id   = 0,
		name = fmt.ctprint(name),
		add  = raw_data(&add_ids),
	}
	system_desc := System_Desc {
		entity = entity_init(world, &entity_desc),
		query = {expr = expr},
		callback = callback,
	}
	return system_init(world, &system_desc)
}

type_name_from_typeid :: proc(tid: typeid) -> string {
	ti := type_info_of(tid)
	if ti != nil {
		if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
			if named.name != "" {
				return named.name
			}
		}
	}

	return fmt.tprint(tid)
}

register_meta_from_rtti :: proc(world: ^World, component_entity: Entity, tid: typeid) {
	// This import is idempotent and ensures builtin meta entities are available.
	//FlecsMetaImport(world)

	info := type_info_of(tid)
	if info == nil {
		return
	}

	if kind, ok := info.variant.(runtime.Type_Info_Named); ok {
		info = kind.base
	}

	#partial switch t in info.variant {
	case runtime.Type_Info_Enum:
		register_enum_meta(world, component_entity, t)
	case runtime.Type_Info_Bit_Set:
		register_bitset_meta(world, component_entity, t)
	case runtime.Type_Info_Array:
		register_array_meta(world, component_entity, t)
	case runtime.Type_Info_Struct:
		register_struct_meta(world, component_entity, t)
	case:
		if kind, ok := primitive_kind_from_info(info); ok {
			_ = primitive_init(world, &Primitive_Desc{entity = component_entity, kind = kind})
		}
	}
}

register_struct_meta :: proc(
	world: ^World,
	component_entity: Entity,
	s: runtime.Type_Info_Struct,
) {
	desc := Struct_Desc {
		entity                 = component_entity,
		create_member_entities = true,
	}

	for i in 0 ..< s.field_count {
		field_ti := s.types[i]
		if field_ti == nil {
			continue
		}

		member_type := meta_type_entity_from_info(field_ti)
		if member_type == 0 {
			continue
		}

		member_count := i32(0)
		base_field := runtime.type_info_base(field_ti)
		if arr, ok := base_field.variant.(runtime.Type_Info_Array); ok {
			member_count = i32(arr.count)
			member_type = meta_type_entity_from_info(arr.elem)
			if member_type == 0 {
				continue
			}
		}

		name_cstr := strings.clone_to_cstring(s.names[i], context.temp_allocator)
		desc.members[i] = Member {
			name       = name_cstr,
			type       = member_type,
			count      = member_count,
			offset     = i32(s.offsets[i]),
			use_offset = true,
		}
	}
	_ = struct_init(world, &desc)
}

register_array_meta :: proc(world: ^World, component_entity: Entity, s: runtime.Type_Info_Array) {
	// TODO
	desc := Array_Desc {
		entity = component_entity,
		type   = meta_type_entity_from_info(s.elem),
		count  = i32(s.count),
	}
	_ = array_init(world, &desc)
}

register_enum_meta :: proc(world: ^World, component_entity: Entity, e: runtime.Type_Info_Enum) {
	desc: Enum_Desc
	desc.entity = component_entity
	desc.underlying_type = meta_type_entity_from_info(e.base)

	count := min(min(len(e.names), len(e.values)), len(desc.constants))
	for i in 0 ..< count {
		desc.constants[i] = {
			name           = strings.clone_to_cstring(e.names[i], context.temp_allocator),
			value          = i64(e.values[i]),
			value_unsigned = u64(e.values[i]),
		}
	}

	_ = enum_init(world, &desc)
}

register_bitset_meta :: proc(
	world: ^World,
	component_entity: Entity,
	b: runtime.Type_Info_Bit_Set,
) {
	desc: Bitmask_Desc
	desc.entity = component_entity

	if b.elem == nil {
		_ = bitmask_init(world, &desc)
		return
	}

	elem_base := runtime.type_info_base(b.elem)
	e, ok := elem_base.variant.(runtime.Type_Info_Enum)
	if !ok {
		_ = bitmask_init(world, &desc)
		return
	}

	count := min(min(len(e.names), len(e.values)), len(desc.constants))
	for i in 0 ..< count {
		val := i64(e.values[i])
		if val < 0 || val >= 64 {
			continue
		}

		desc.constants[i] = {
			name  = strings.clone_to_cstring(e.names[i], context.temp_allocator),
			value = Flags64(1 << u64(val)),
		}
	}

	_ = bitmask_init(world, &desc)
}

meta_type_entity_from_info :: proc(info: ^runtime.Type_Info) -> Entity {
	if info == nil {
		return 0
	}

	if info.id == typeid_of(Entity) {
		return FLECS_IDecs_entity_tID_
	}
	if info.id == typeid_of(Id) {
		return FLECS_IDecs_id_tID_
	}

	if kind, ok := primitive_kind_from_info(info); ok {
		switch kind {
		case .Bool:
			return FLECS_IDecs_bool_tID_
		case .Char:
			return FLECS_IDecs_i8_tID_
		case .Byte:
			return FLECS_IDecs_u8_tID_
		case .U8:
			return FLECS_IDecs_u8_tID_
		case .U16:
			return FLECS_IDecs_u16_tID_
		case .U32:
			return FLECS_IDecs_u32_tID_
		case .U64:
			return FLECS_IDecs_u64_tID_
		case .I8:
			return FLECS_IDecs_i8_tID_
		case .I16:
			return FLECS_IDecs_i16_tID_
		case .I32:
			return FLECS_IDecs_i32_tID_
		case .I64:
			return FLECS_IDecs_i64_tID_
		case .UPtr:
			return FLECS_IDecs_uptr_tID_
		case .IPtr:
			return FLECS_IDecs_iptr_tID_
		case .F32:
			return FLECS_IDecs_f32_tID_
		case .F64:
			return FLECS_IDecs_f64_tID_
		case .String:
			return FLECS_IDecs_string_tID_
		case .Entity:
			return FLECS_IDecs_entity_tID_
		case .Id:
			return FLECS_IDecs_id_tID_
		}
	}

	// Non-primitive nested member types are not auto-registered here yet.
	return 0
}

primitive_kind_from_info :: proc(info: ^runtime.Type_Info) -> (Primitive_Kind, bool) {
	core := runtime.type_info_core(info)
	if core == nil {
		return {}, false
	}

	#partial switch t in core.variant {
	case runtime.Type_Info_Boolean:
		return .Bool, true
	case runtime.Type_Info_String:
		return .String, true
	case runtime.Type_Info_Integer:
		if t.signed {
			switch core.size {
			case 1:
				return .I8, true
			case 2:
				return .I16, true
			case 4:
				return .I32, true
			case 8:
				return .I64, true
			}
		} else {
			switch core.size {
			case 1:
				return .U8, true
			case 2:
				return .U16, true
			case 4:
				return .U32, true
			case 8:
				return .U64, true
			}
		}
	case runtime.Type_Info_Float:
		switch core.size {
		case 4:
			return .F32, true
		case 8:
			return .F64, true
		}
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer:
		return .UPtr, true
	}

	return {}, false
}
