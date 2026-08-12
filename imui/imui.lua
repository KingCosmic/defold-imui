local context_module = require "imui.context"
local layout = require "imui.layout"
local renderer = require "imui.renderer"

local M = {}
local CURRENT = nil
local EMPTY_STYLE = {}

local function require_current()
	assert(CURRENT, "imui widget functions must be called between begin_frame() and end_frame()")
	return CURRENT
end

local function point_in_rect(x, y, left, top, width, height)
	return x >= left and x <= left + width and y <= top and y >= top - height
end

local function clear_drag_regions(context)
	context_module.clear_map(
		context.drag_sources
	)

	context_module.clear_map(
		context.drop_targets
	)

	for index = 1, context.drag_source_order_count do
		context.drag_source_order[index] = nil
	end

	for index = 1, context.drop_target_order_count do
		context.drop_target_order[index] = nil
	end

	context.drag_source_order_count = 0
	context.drop_target_order_count = 0
end

local function add_drag_source(
	context,
	command,
	x,
	y,
	width,
	height
)
	local spec = command.drag_source

	if not spec then
		return
	end

	local source = context.drag_sources[command.id]

	if not source then
		source = {}
		context.drag_sources[command.id] = source
	end

	source.id = command.id
	source.type = spec.type
	source.payload = spec.payload

	source.preview = spec.preview

	source.x = x
	source.y = y
	source.width = width
	source.height = height

	source.enabled =
		width > 0
		and height > 0

	if source.enabled then
		context.drag_source_order_count =
			context.drag_source_order_count + 1

		context.drag_source_order[
			context.drag_source_order_count
		] = command.id
	end
end

local function add_drop_target(
	context,
	command,
	x,
	y,
	width,
	height
)
	local spec = command.drop_target

	if not spec then
		return
	end

	local target =
		context.drop_targets[command.id]

	if not target then
		target = {}
		context.drop_targets[command.id] = target
	end

	target.id = command.id
	target.accept = spec.accept

	target.x = x
	target.y = y
	target.width = width
	target.height = height

	target.enabled =
		width > 0
		and height > 0

	if target.enabled then
		context.drop_target_order_count =
			context.drop_target_order_count + 1

		context.drop_target_order[
			context.drop_target_order_count
		] = command.id
	end
end

local function find_drag_source_at(
	context,
	x,
	y
)
	for index =
		context.drag_source_order_count,
		1,
		-1
	do
		local id =
			context.drag_source_order[index]

		local source =
			context.drag_sources[id]

		if source
			and source.enabled
			and point_in_rect(
				x,
				y,
				source.x,
				source.y,
				source.width,
				source.height
			)
		then
			return id
		end
	end

	return nil
end

local function target_accepts_drag(
	target,
	drag
)
	if not target or not target.enabled then
		return false
	end

	local accept = target.accept

	if accept == nil then
		return true
	end

	if type(accept) == "string" then
		return accept == drag.type
	end

	if type(accept) == "function" then
		return accept(
			drag.payload,
			drag.type,
			drag.source_id
		)
	end

	if type(accept) == "table" then
		for _, accepted_type in ipairs(accept) do
			if accepted_type == drag.type then
				return true
			end
		end
	end

	return false
end

local function find_drop_target_at(
	context,
	x,
	y,
	drag
)
	for index =
		context.drop_target_order_count,
		1,
		-1
	do
		local id =
			context.drop_target_order[index]

		local target =
			context.drop_targets[id]

		if target
			and point_in_rect(
				x,
				y,
				target.x,
				target.y,
				target.width,
				target.height
			)
			and target_accepts_drag(
				target,
				drag
			)
		then
			return id
		end
	end

	return nil
end

local function try_start_drag_source(
	context,
	x,
	y
)
	local candidate_id =
		context.drag_source_candidate_id

	if not context.pointer_down
		or not candidate_id
	then
		return false
	end

	local delta_x =
		x - context.pointer_press_x

	local delta_y =
		y - context.pointer_press_y

	local distance_squared =
		delta_x * delta_x
		+ delta_y * delta_y

	if distance_squared
		< context.drag_threshold
			* context.drag_threshold
	then
		return false
	end

	local source =
		context.drag_sources[candidate_id]

	if not source then
		return false
	end

	local drag =
		context.drag_state

	drag.active = true
	drag.source_id = source.id
	drag.target_id = nil

	drag.type = source.type
	drag.payload = source.payload

	local preview = source.preview

	if type(preview) == "function" then
		preview = preview(
			source.payload,
			source.type,
			source.id
		)
	end

	drag.preview = preview

	drag.start_x =
		context.pointer_press_x

	drag.start_y =
		context.pointer_press_y

	drag.x = x
	drag.y = y

	-- Item drag wins over button click and
	-- scroll-content dragging.
	context.active_id = nil

	context.drag_scroll_id = nil
	context.drag_scroll_candidate_id = nil

	return true
end

local function update_drag_source(
	context,
	x,
	y
)
	local drag =
		context.drag_state

	if not drag.active then
		return
	end

	drag.x = x
	drag.y = y

	drag.target_id =
		find_drop_target_at(
			context,
			x,
			y,
			drag
		)
end

local function finish_drag_source(
	context,
	x,
	y
)
	local drag =
		context.drag_state

	if not drag.active then
		return false
	end

	update_drag_source(
		context,
		x,
		y
	)

	local target_id =
		drag.target_id

	if target_id then
		context.drop_events[target_id] = {
			source_id =
				drag.source_id,

			target_id =
				target_id,

			type =
				drag.type,

			payload =
				drag.payload,

			x = x,
			y = y,
		}
	end

	drag.active = false
	drag.source_id = nil
	drag.target_id = nil
	drag.type = nil
	drag.payload = nil

	drag.preview = nil

	context.drag_source_candidate_id = nil

	return true
end

local function clamp(value, minimum, maximum)
	if value < minimum then
		return minimum
	end
	if value > maximum then
		return maximum
	end
	return value
end

local function intersect_rect(ax, ay, aw, ah, bx, by, bw, bh)
	local left = math.max(ax, bx)
	local right = math.min(ax + aw, bx + bw)
	local top = math.min(ay, by)
	local bottom = math.max(ay - ah, by - bh)
	return left, top, math.max(0, right - left), math.max(0, top - bottom)
end

local function clipped_rect(context, x, y, width, height, clip_id)
	local current_clip_id = clip_id
	while current_clip_id do
		local state = context.scroll_states[current_clip_id]
		if not state then
			break
		end

		x, y, width, height = intersect_rect(
			x,
			y,
			width,
			height,
			state.viewport_x,
			state.viewport_y,
			state.viewport_width,
			state.viewport_height
		)

		if width <= 0 or height <= 0 then
			return x, y, 0, 0
		end

		current_clip_id = state.parent_clip_id
	end

	return x, y, width, height
end

local function hit_test(context, x, y)
	for index = context.hit_order_count, 1, -1 do
		local id = context.hit_order[index]
		local widget = context.widgets[id]
		if widget and widget.hit_enabled then
			if point_in_rect(x, y, widget.hit_x, widget.hit_y, widget.hit_width, widget.hit_height) then
				return id
			end
		end
	end
	return nil
end

local function scroll_can_move(state)
	if state.axis == "horizontal" then
		return state.max_x > 0
	elseif state.axis == "both" then
		return state.max_x > 0 or state.max_y > 0
	end
	return state.max_y > 0
end

local function find_scrollbar_thumb_at(
	context,
	x,
	y
)
	for index = context.scroll_order_count, 1, -1 do
		local id =
		context.scroll_order[index]

		local state =
		context.scroll_states[id]

		if state
			and state.scrollbar_hit_enabled
			and point_in_rect(
				x,
				y,
				state.scrollbar_hit_x,
				state.scrollbar_hit_y,
				state.scrollbar_hit_width,
				state.scrollbar_hit_height
			)
		then
			return id
		end
	end

	return nil
end

local function find_scroll_at(context, x, y, require_scrollable)
	for index = context.scroll_order_count, 1, -1 do
		local id = context.scroll_order[index]
		local state = context.scroll_states[id]
		if state and state.hit_enabled then
			if point_in_rect(x, y, state.hit_x, state.hit_y, state.hit_width, state.hit_height) then
				if not require_scrollable or scroll_can_move(state) then
					return id
				end
			end
		end
	end
	return nil
end

local function scroll_by_wheel(state, steps)
	local amount = steps * state.wheel_speed
	if state.axis == "horizontal" then
		state.x = clamp(state.x + amount, 0, state.max_x)
	elseif state.axis == "both" then
		if state.max_y > 0 then
			state.y = clamp(state.y + amount, 0, state.max_y)
		else
			state.x = clamp(state.x + amount, 0, state.max_x)
		end
	else
		state.y = clamp(state.y + amount, 0, state.max_y)
	end
end

local function update_drag(context, x, y)
	local candidate_id = context.drag_scroll_candidate_id
	if not context.pointer_down or not candidate_id then
		return
	end

	local state = context.scroll_states[candidate_id]
	if not state or not state.drag_enabled then
		return
	end

	local delta_x = x - context.drag_start_x
	local delta_y = y - context.drag_start_y

	if not context.drag_scroll_id then
		local distance_squared = delta_x * delta_x + delta_y * delta_y
		if distance_squared < context.drag_threshold * context.drag_threshold then
			return
		end

		context.drag_scroll_id = candidate_id
		context.active_id = nil
	end

	if state.axis == "horizontal" or state.axis == "both" then
		state.x = clamp(context.drag_start_scroll_x - delta_x, 0, state.max_x)
	end
	if state.axis == "vertical" or state.axis == "both" then
		state.y = clamp(context.drag_start_scroll_y - delta_y, 0, state.max_y)
	end
end

local function update_scrollbar_drag(
	context,
	x,
	y
)
	local id =
		context.scrollbar_drag_id

	if not id or not context.pointer_down then
		return
	end

	local state = context.scroll_states[id]

	if not state
	or not state.scrollbar_visible
	or state.max_y <= 0
	then
		return
	end

	local travel = math.max(
		0,
		state.scrollbar_track_height
		- state.scrollbar_thumb_height
	)

	if travel <= 0 then
		state.y = 0
		return
	end

	local desired_thumb_y =
		y + context.scrollbar_drag_offset_y

	local minimum_thumb_y =
		state.scrollbar_track_y - travel

	local maximum_thumb_y = state.scrollbar_track_y

	desired_thumb_y = clamp(
		desired_thumb_y,
		minimum_thumb_y,
		maximum_thumb_y
	)

	local progress =
		(
			state.scrollbar_track_y
			- desired_thumb_y
		) / travel

	state.y =
	clamp(
		progress * state.max_y,
		0,
		state.max_y
	)
end

local function process_input(context)
	for index = 1, context.input_event_count do
		local event =
		context.input_events[index]

		context.input_x = event.x
		context.input_y = event.y

		local hovered_scrollbar =
		find_scrollbar_thumb_at(
			context,
			event.x,
			event.y
		)

		context.hovered_scrollbar_id = hovered_scrollbar

		if hovered_scrollbar then
			context.hovered_id = nil
		else
			context.hovered_id =
			hit_test(
			context,
			event.x,
			event.y
		)
	end

	if event.type == "moved" then
		if context.scrollbar_drag_id then
			update_scrollbar_drag(
				context,
				event.x,
				event.y
			)

		elseif context.drag_state.active then
			update_drag_source(
				context,
				event.x,
				event.y
			)

		elseif context.drag_source_candidate_id then
			local started =
				try_start_drag_source(
					context,
					event.x,
					event.y
				)

			if started then
				update_drag_source(
					context,
					event.x,
					event.y
				)
			end

		else
			update_drag(
				context,
				event.x,
				event.y
			)
		end
	elseif event.type == "pressed" then
		context.pointer_down = true
		context.pointer_press_x = event.x
		context.pointer_press_y = event.y

		if hovered_scrollbar then
			local state =
			context.scroll_states[
				hovered_scrollbar
			]

			context.scrollbar_drag_id =
			hovered_scrollbar

			-- Preserve where inside the thumb the
			-- pointer was pressed.
			context.scrollbar_drag_offset_y =
			state.scrollbar_thumb_y
			- event.y

			context.active_id = nil
			context.drag_scroll_id = nil
			context.drag_scroll_candidate_id = nil
		else
			context.scrollbar_drag_id = nil
			context.active_id = context.hovered_id

			context.drag_source_candidate_id =
				find_drag_source_at(
					context,
					event.x,
					event.y
				)

			local scroll_id =
			find_scroll_at(
				context,
				event.x,
				event.y,
				true
			)

			context.drag_scroll_candidate_id =
			scroll_id

			context.drag_scroll_id = nil

			if scroll_id then
				local state =
					context.scroll_states[
					scroll_id
				]

				context.drag_start_x =
				event.x

				context.drag_start_y =
				event.y

				context.drag_start_scroll_x =
				state.x

				context.drag_start_scroll_y =
				state.y
			end
		end

	elseif event.type == "released" then
		local was_item_drag = context.drag_state.active

		if was_item_drag then
			finish_drag_source(
				context,
				event.x,
				event.y
			)
		end

		local was_scrollbar_drag =
			context.scrollbar_drag_id ~= nil

		if not context.drag_scroll_id
			and not context.scrollbar_drag_id
			and not was_item_drag
		then
			if context.active_id
				and context.active_id
					== context.hovered_id
			then
				context.clicked_ids[
					context.active_id
				] = true
			end
		end

		context.pointer_down = false
		context.active_id = nil

		context.scrollbar_drag_id = nil

		context.drag_scroll_id = nil
		context.drag_scroll_candidate_id = nil

		context.drag_source_candidate_id = nil

		elseif event.type == "wheel" then
			local scroll_id =
			find_scroll_at(
				context,
				event.x,
				event.y,
				true
			)

			if scroll_id then
				scroll_by_wheel(
					context.scroll_states[
					scroll_id
					],
					event.value
				)
			end
		end
	end

	context.hovered_scrollbar_id =
	find_scrollbar_thumb_at(
		context,
		context.input_x,
		context.input_y
	)

	if context.hovered_scrollbar_id then
		context.hovered_id = nil
	else
		context.hovered_id =
		hit_test(
			context,
			context.input_x,
			context.input_y
		)
	end

	context_module.clear_input(context)
end

local function resolve_id(parent, local_id)
	local value = tostring(local_id)
	if parent.kind == "root" then
		return value
	end
	return parent.id .. "/" .. value
end

local function declare(kind, local_id, style)
	local context = require_current()
	assert(local_id ~= nil, "imui widgets require a stable id")

	local parent = context_module.current_container(context)
	local id = resolve_id(parent, local_id)
	assert(not context.current_ids[id], "duplicate imui id in frame: " .. id)
	context.current_ids[id] = true

	local command = context_module.acquire_command(context)
	command.id = id
	command.local_id = local_id
	command.kind = kind
	command.parent = parent
	command.style = style or EMPTY_STYLE
	command.drag_source = command.style.drag_source
	command.drop_target = command.style.drop_target
	command.outer_clip_id = parent.clip_id

	if kind == "scroll" then
		command.clip_id = id
	else
		command.clip_id = parent.clip_id
	end

	parent.child_count = parent.child_count + 1
	parent.children[parent.child_count] = command
	return command
end

local function begin_container(local_id, direction, style)
	local context = require_current()
	local command = declare("container", local_id, style)
	command.direction = direction
	context_module.push_container(context, command)
	return command
end

local function rebuild_interaction_regions(context)
	clear_drag_regions(context)

	for index = 1, context.hit_order_count do
		context.hit_order[index] = nil
	end
	context.hit_order_count = 0

	for index = 1, context.scroll_order_count do
		context.scroll_order[index] = nil
	end
	context.scroll_order_count = 0

	for index = 2, context.command_count do
		local command = context.commands[index]
		local widget = command.widget
		local style = command.style
		local enabled = style.enabled ~= false
		local visible = style.visible ~= false

		local region_x, region_y, region_width, region_height =
			clipped_rect(
				context,
				command.layout_x,
				command.layout_y,
				command.layout_width,
				command.layout_height,
				command.clip_id
			)

		if enabled and visible then
			add_drag_source(
				context,
				command,
				region_x,
				region_y,
				region_width,
				region_height
			)

			add_drop_target(
				context,
				command,
				region_x,
				region_y,
				region_width,
				region_height
			)
		end

		if command.kind == "scroll" then
			local state = command.scroll_state
			local x, y, width, height = clipped_rect(
				context,
				command.layout_x,
				command.layout_y,
				command.layout_width,
				command.layout_height,
				command.outer_clip_id
			)

			state.hit_x = x
			state.hit_y = y
			state.hit_width = width
			state.hit_height = height
			state.hit_enabled = enabled and visible and width > 0 and height > 0

			if state.hit_enabled then
				context.scroll_order_count = context.scroll_order_count + 1
				context.scroll_order[context.scroll_order_count] = command.id
			end

			state.scrollbar_hit_enabled = false

			if state.scrollbar_visible then
				local hit_padding =
				state.scrollbar_hit_padding or 0

				local thumb_x =
				state.scrollbar_thumb_x
				- hit_padding

				local thumb_y =
				state.scrollbar_thumb_y
				+ hit_padding

				local thumb_width =
				state.scrollbar_thumb_width
				+ hit_padding * 2

				local thumb_height =
				state.scrollbar_thumb_height
				+ hit_padding * 2

				local x, y, width, height =
				clipped_rect(
					context,
					thumb_x,
					thumb_y,
					thumb_width,
					thumb_height,
					command.outer_clip_id
				)

				state.scrollbar_hit_x = x
				state.scrollbar_hit_y = y
				state.scrollbar_hit_width = width
				state.scrollbar_hit_height = height

				state.scrollbar_hit_enabled =
				enabled
				and visible
				and width > 0
				and height > 0
			end
		end

		if widget then
			local x, y, width, height = clipped_rect(
				context,
				command.layout_x,
				command.layout_y,
				command.layout_width,
				command.layout_height,
				command.clip_id
			)

			widget.hit_enabled = command.interactive and enabled and visible and width > 0 and height > 0
			widget.hit_x = x
			widget.hit_y = y
			widget.hit_width = width
			widget.hit_height = height

			if widget.hit_enabled then
				context.hit_order_count = context.hit_order_count + 1
				context.hit_order[context.hit_order_count] = command.id
			end
		end
	end
end

function M.create(options)
	return context_module.create(options)
end

function M.destroy(context)
	assert(not context.is_building, "cannot destroy an imui context during a frame")
	renderer.destroy(context)
end

function M.begin_frame(context, dt)
	assert(context, "imui.begin_frame() requires a context")
	assert(not CURRENT, "another imui context is already building a frame")
	assert(not context.is_building, "imui.begin_frame() called twice")

	CURRENT = context
	context.is_building = true
	context.frame = context.frame + 1
	context.dt = dt or 0

	context_module.begin_commands(context)
	process_input(context)

	local root = context_module.acquire_command(context)
	root.id = "__root"
	root.local_id = "__root"
	root.kind = "root"
	root.direction = "overlay"
	root.style = EMPTY_STYLE
	root.clip_id = nil
	root.outer_clip_id = nil
	context_module.push_container(context, root)
end

function M.end_frame()
	local context = require_current()
	assert(context.container_stack_count == 1, "an imui container was not closed with end_container()")

	renderer.prepare(context)
	layout.compute(context, context.commands[1])
	renderer.apply(context)
	rebuild_interaction_regions(context)

	context.container_stack[1] = nil
	context.container_stack_count = 0
	context.is_building = false
	CURRENT = nil
end

function M.on_input(context, action_id, action)
	assert(context, "imui.on_input() requires a context")

	local x = action.x or context.input_x
	local y = action.y or context.input_y
	local has_position = action.x ~= nil and action.y ~= nil

	if has_position then
		context_module.queue_input(context, "moved", x, y)
	end

	if action_id == context.pointer_action then
		if action.pressed then
			context_module.queue_input(context, "pressed", x, y)
		end
		if action.released then
			context_module.queue_input(context, "released", x, y)
		end
	elseif action_id == context.scroll_up_action then
		if action.value == nil or action.value ~= 0 then
			context_module.queue_input(context, "wheel", x, y, -1)
		end
	elseif action_id == context.scroll_down_action then
		if action.value == nil or action.value ~= 0 then
			context_module.queue_input(context, "wheel", x, y, 1)
		end
	end

	local hovered = hit_test(context, x, y)
	local scroll_id = find_scroll_at(context, x, y, false)
	local scrollbar_id = find_scrollbar_thumb_at(context, x, y)
	return context.active_id ~= nil
		or context.scrollbar_drag_id ~= nil
		or context.drag_scroll_candidate_id ~= nil
		or hovered ~= nil
		or scrollbar_id ~= nil
		or scroll_id ~= nil
end

function M.begin_column(id, style)
	return begin_container(id, "column", style)
end

function M.begin_row(id, style)
	return begin_container(id, "row", style)
end

function M.begin_overlay(id, style)
	return begin_container(id, "overlay", style)
end

function M.begin_grid(id, style)
	style = style or EMPTY_STYLE
	assert(style.columns == nil or style.columns >= 1, "grid columns must be at least 1")
	return begin_container(id, "grid", style)
end

function M.begin_scroll(id, style)
	local context = require_current()
	style = style or EMPTY_STYLE

	local command = declare("scroll", id, style)

	command.scroll_axis = style.axis or "vertical"

	command.content_direction =
		style.content_direction
		or (
			command.scroll_axis == "horizontal"
			and "row"
			or "column"
		)

	local state =
		context_module.get_scroll_state(context, command.id)

	command.scroll_state = state

	state.last_seen_frame = context.frame

	state.drag_enabled = style.drag_enabled ~= false

	state.wheel_speed =
		style.wheel_speed
		or context.defaults.scroll_wheel_speed

	if style.scrollbar == nil then
		state.scrollbar_enabled =
		context.defaults.scrollbar_enabled
	else
		state.scrollbar_enabled =
		style.scrollbar == true
	end

	state.scrollbar_width =
		style.scrollbar_width
		or context.defaults.scrollbar_width

	state.scrollbar_margin =
		style.scrollbar_margin
		or context.defaults.scrollbar_margin

	state.scrollbar_min_thumb =
		style.scrollbar_min_thumb
		or context.defaults.scrollbar_min_thumb

	state.scrollbar_hit_padding =
		style.scrollbar_hit_padding
		or context.defaults.scrollbar_hit_padding

	context_module.push_container(context, command)

	return state
end

function M.end_container()
	context_module.pop_container(require_current())
end

function M.box(id, style)
	return declare("box", id, style)
end

function M.spacer(id, style)
	return declare("spacer", id, style)
end

function M.text(id, text, style)
	local command = declare("text", id, style)
	command.text = tostring(text or "")
	return command
end

function M.button(id, text, style)
	local context = require_current()
	local command = declare("button", id, style)
	command.text = tostring(text or "")
	command.interactive = true
	return context.clicked_ids[command.id] == true
end

function M.is_hovered(id)
	local context = require_current()
	local parent = context_module.current_container(context)
	return context.hovered_id == resolve_id(parent, id)
end

function M.is_active(id)
	local context = require_current()
	local parent = context_module.current_container(context)
	return context.active_id == resolve_id(parent, id)
end

function M.set_scroll(context, id, x, y)
	local state = context_module.get_scroll_state(context, id)
	if x ~= nil then
		state.x = clamp(x, 0, state.max_x)
	end
	if y ~= nil then
		state.y = clamp(y, 0, state.max_y)
	end
end

function M.get_scroll(context, id)
	return context.scroll_states[id]
end

function M.get_drag()
	local context =
		require_current()

	if context.drag_state.active then
		return context.drag_state
	end

	return nil
end

function M.is_drag_over(id)
	local context =
		require_current()

	local parent =
		context_module.current_container(
			context
		)

	local resolved =
		resolve_id(parent, id)

	return context.drag_state.active
		and context.drag_state.target_id
			== resolved
end

function M.current_drop()
	local context =
		require_current()

	local container =
		context_module.current_container(
			context
		)

	return context.drop_events[
		container.id
	]
end

return M
