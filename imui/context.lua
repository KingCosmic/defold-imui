local M = {}

local function clear_map(map)
	for key in pairs(map) do
		map[key] = nil
	end
end

local function clear_array(array, count)
	for index = 1, count or #array do
		array[index] = nil
	end
end

function M.create(options)
	options = options or {}

	return {
		frame = 0,
		dt = 0,
		is_building = false,

		pointer_action = options.pointer_action or hash("touch"),
		scroll_up_action = options.scroll_up_action or hash("mouse_wheel_up"),
		scroll_down_action = options.scroll_down_action or hash("mouse_wheel_down"),
		input_x = 0,
		input_y = 0,
		input_events = {},
		input_event_count = 0,
		pointer_down = false,
		pointer_press_x = 0,
		pointer_press_y = 0,

		hovered_id = nil,
		active_id = nil,
		clicked_ids = {},

		drag_scroll_id = nil,
		drag_scroll_candidate_id = nil,
		drag_start_x = 0,
		drag_start_y = 0,
		drag_start_scroll_x = 0,
		drag_start_scroll_y = 0,
		drag_threshold = options.drag_threshold or 8,

		hovered_scrollbar_id = nil,
		scrollbar_drag_id = nil,
		scrollbar_drag_offset_y = 0,

		commands = {},
		command_count = 0,
		current_ids = {},
		container_stack = {},
		container_stack_count = 0,

		widgets = {},
		hit_order = {},
		hit_order_count = 0,
		stale_ids = {},
		stale_id_count = 0,

		scroll_states = {},
		scroll_order = {},
		scroll_order_count = 0,

		current_render_nodes = {},
		current_render_node_count = 0,
		last_render_nodes = {},
		last_render_node_count = 0,

		current_render_groups = {},
		last_render_groups = {},

		defaults = {
			font = options.font,
			text_color = options.text_color or vmath.vector4(1, 1, 1, 1),
			text_scale = options.text_scale or 1,
			button_color = options.button_color or vmath.vector4(0.18, 0.20, 0.24, 1),
			button_hover_color = options.button_hover_color or vmath.vector4(0.25, 0.28, 0.34, 1),
			button_pressed_color = options.button_pressed_color or vmath.vector4(0.12, 0.14, 0.18, 1),
			button_text_color = options.button_text_color or options.text_color or vmath.vector4(1, 1, 1, 1),
			button_padding_x = options.button_padding_x or 16,
			button_padding_y = options.button_padding_y or 10,
			scroll_wheel_speed = options.scroll_wheel_speed or 48,
			scrollbar_enabled =
			options.scrollbar_enabled == true,

			scrollbar_width = options.scrollbar_width or 8,
			scrollbar_margin = options.scrollbar_margin or 5,

			scrollbar_min_thumb = options.scrollbar_min_thumb or 28,

			scrollbar_hit_padding = options.scrollbar_hit_padding or 4,

			scrollbar_track_color =
				options.scrollbar_track_color
				or vmath.vector4(1, 1, 1, 0.10),

			scrollbar_thumb_color =
				options.scrollbar_thumb_color
				or vmath.vector4(0.55, 0.58, 0.66, 0.75),

			scrollbar_thumb_hover_color =
				options.scrollbar_thumb_hover_color
				or vmath.vector4(0.70, 0.73, 0.82, 0.90),

			scrollbar_thumb_pressed_color =
				options.scrollbar_thumb_pressed_color
				or vmath.vector4(0.82, 0.84, 0.92, 1),
		},
	}
end

function M.begin_commands(context)
	context.command_count = 0
	context.container_stack_count = 0
	clear_map(context.current_ids)
	clear_map(context.clicked_ids)
end

function M.acquire_command(context)
	context.command_count = context.command_count + 1
	local index = context.command_count
	local command = context.commands[index]

	if not command then
		command = {
			children = {},
			child_count = 0,
		}
		context.commands[index] = command
	else
		clear_array(command.children, command.child_count)
		command.child_count = 0
	end

	command.index = index
	command.id = nil
	command.local_id = nil
	command.kind = nil
	command.direction = nil
	command.parent = nil
	command.style = nil
	command.text = nil
	command.interactive = false
	command.widget = nil
	command.clip_id = nil
	command.outer_clip_id = nil
	command.scroll_state = nil
	command.scroll_axis = nil
	command.content_direction = nil
	command.intrinsic_width = 0
	command.intrinsic_height = 0
	command.measured_width = 0
	command.measured_height = 0
	command.content_width = 0
	command.content_height = 0
	command.layout_x = 0
	command.layout_y = 0
	command.layout_width = 0
	command.layout_height = 0
	command.label_width = 0
	command.label_height = 0
	command.grid_columns = 1
	command.grid_rows = 0
	command.grid_cell_width = 0
	command.grid_cell_height = 0
	command.grid_column_gap = 0
	command.grid_row_gap = 0

	return command
end

function M.push_container(context, command)
	context.container_stack_count = context.container_stack_count + 1
	context.container_stack[context.container_stack_count] = command
end

function M.pop_container(context)
	local count = context.container_stack_count
	assert(count > 1, "imui.end_container() called without a matching begin container")
	context.container_stack[count] = nil
	context.container_stack_count = count - 1
end

function M.current_container(context)
	return context.container_stack[context.container_stack_count]
end

function M.queue_input(context, event_type, x, y, value)
	context.input_event_count = context.input_event_count + 1
	local event = context.input_events[context.input_event_count]

	if not event then
		event = {}
		context.input_events[context.input_event_count] = event
	end

	event.type = event_type
	event.x = x
	event.y = y
	event.value = value
end

function M.clear_input(context)
	for index = 1, context.input_event_count do
		local event = context.input_events[index]
		event.type = nil
		event.value = nil
	end
	context.input_event_count = 0
end

function M.get_scroll_state(context, id)
	local state = context.scroll_states[id]
	if not state then
		state = {
			id = id,
			x = 0,
			y = 0,
			max_x = 0,
			max_y = 0,
			viewport_x = 0,
			viewport_y = 0,
			viewport_width = 0,
			viewport_height = 0,
			content_width = 0,
			content_height = 0,
			parent_clip_id = nil,
			axis = "vertical",
			drag_enabled = true,
			wheel_speed = context.defaults.scroll_wheel_speed,
			last_seen_frame = 0,
			scrollbar_enabled = false,
			scrollbar_visible = false,

			scrollbar_width = 8,
			scrollbar_margin = 5,
			scrollbar_min_thumb = 28,
			scrollbar_hit_padding = 4,

			scrollbar_track_x = 0,
			scrollbar_track_y = 0,
			scrollbar_track_width = 0,
			scrollbar_track_height = 0,

			scrollbar_thumb_x = 0,
			scrollbar_thumb_y = 0,
			scrollbar_thumb_width = 0,
			scrollbar_thumb_height = 0,

			scrollbar_hit_x = 0,
			scrollbar_hit_y = 0,
			scrollbar_hit_width = 0,
			scrollbar_hit_height = 0,
			scrollbar_hit_enabled = false,
		}
		context.scroll_states[id] = state
	end
	return state
end

function M.clear_map(map)
	clear_map(map)
end

return M
