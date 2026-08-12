local M = {}

local ZERO_POSITION = vmath.vector3(0, 0, 0)
local ONE_SIZE = vmath.vector3(1, 1, 0)
local ROOT_GROUP = "__imui_root_group"

local function vector4_equal(a, b)
	return a == b or (
		a and b and
		a.x == b.x and
		a.y == b.y and
		a.z == b.z and
		a.w == b.w
	)
end

local function vector3_equal(a, b)
	return a == b or (
		a and b and
		a.x == b.x and
		a.y == b.y and
		a.z == b.z
	)
end

local function for_each_node(widget, callback)
	if not widget or not widget.nodes then
		return
	end

	for _, node in pairs(widget.nodes) do
		if node then
			callback(node)
		end
	end
end

local function detach_nodes(widget)
	for_each_node(widget, function(node)
		if gui.get_parent(node) then
			gui.set_parent(node, nil, true)
		end
	end)
end

local function delete_nodes(widget)
	for_each_node(widget, function(node)
		gui.delete_node(node)
	end)
end

local function new_box(id)
	local node = gui.new_box_node(ZERO_POSITION, ONE_SIZE)
	gui.set_id(node, hash("imui/" .. id))
	gui.set_pivot(node, gui.PIVOT_NW)
	gui.set_size_mode(node, gui.SIZE_MODE_MANUAL)
	return node
end

local function new_text(id, pivot)
	local node = gui.new_text_node(ZERO_POSITION, "")
	gui.set_id(node, hash("imui/" .. id))
	gui.set_pivot(node, pivot or gui.PIVOT_NW)
	return node
end

local function container_has_visual(command)
	local style = command.style
	return style.background_color ~= nil or style.texture ~= nil
end

local function expected_shape(command)
	if command.kind == "scroll" then
		return "scroll"
	elseif command.kind == "container" then
		return container_has_visual(command) and "box" or "none"
	elseif command.kind == "box" then
		return "box"
	elseif command.kind == "text" then
		return "text"
	elseif command.kind == "button" then
		return "button"
	end
	return "none"
end

local function create_widget(command)
	local shape = expected_shape(command)
	local widget = {
		id = command.id,
		kind = command.kind,
		shape = shape,
		nodes = {},
		applied = {
			background = {},
			label = {},
			clipper = {},
			scrollbar_track = {},
			scrollbar_thumb = {},
		},
		last_seen_frame = 0,
	}

	if shape == "box" then
		widget.nodes.background = new_box(command.id)
	elseif shape == "text" then
		widget.nodes.label = new_text(command.id, gui.PIVOT_NW)
	elseif shape == "button" then
		widget.nodes.background = new_box(command.id .. "/background")
		widget.nodes.label = new_text(command.id .. "/label", gui.PIVOT_CENTER)
	elseif shape == "scroll" then
		widget.nodes.clipper = new_box(command.id .. "/clipper")
		gui.set_pivot(widget.nodes.clipper, gui.PIVOT_SW)
		gui.set_clipping_mode(widget.nodes.clipper, gui.CLIPPING_MODE_STENCIL)
		gui.set_clipping_visible(widget.nodes.clipper, false)

		-- These remain siblings of the clipper rather than
		-- children of it. That keeps them stationary while
		-- the clipped content moves.
		widget.nodes.scrollbar_track = new_box(command.id .. "/scrollbar_track")
		widget.nodes.scrollbar_thumb = new_box(command.id .. "/scrollbar_thumb")
	end

	return widget
end

local function ensure_widget(context, command)
	local expected = expected_shape(command)
	local widget = context.widgets[command.id]

	if widget and (widget.kind ~= command.kind or widget.shape ~= expected) then
		detach_nodes(widget)
		delete_nodes(widget)
		context.widgets[command.id] = nil
		widget = nil
	end

	if not widget then
		widget = create_widget(command)
		context.widgets[command.id] = widget
	end

	widget.last_seen_frame = context.frame
	command.widget = widget
	return widget
end

local function set_text(node, applied, text)
	if applied.text ~= text then
		gui.set_text(node, text)
		applied.text = text
	end
end

local function set_font(node, applied, font)
	if font and applied.font ~= font then
		gui.set_font(node, font)
		applied.font = font
	end
end

local function set_scale(node, applied, scale)
	local value
	if type(scale) == "number" then
		value = vmath.vector3(scale, scale, 1)
	else
		value = scale or vmath.vector3(1, 1, 1)
	end

	if not vector3_equal(applied.scale, value) then
		gui.set_scale(node, value)
		applied.scale = vmath.vector3(value)
	end
end

local function ensure_drag_preview(context)
	if context.drag_preview_nodes then
		return context.drag_preview_nodes
	end

	local background =
		new_box("__imui_drag_preview/background")

	gui.set_pivot(
		background,
		gui.PIVOT_NW
	)

	local label =
		new_text("__imui_drag_preview/label")

	gui.set_pivot(
		label,
		gui.PIVOT_CENTER
	)

	context.drag_preview_nodes = {
		background = background,
		label = label,
	}

	-- They MUST stay at root level or a scroll container
	-- could clip the preview.
	gui.set_parent(
		background,
		nil,
		false
	)

	gui.set_parent(
		label,
		nil,
		false
	)

	gui.set_enabled(background, false)
	gui.set_enabled(label, false)

	gui.set_visible(background, false)
	gui.set_visible(label, false)

	return context.drag_preview_nodes
end

local function prepare_text(context, command, node, applied, text)
	local style = command.style
	local font = style.font or context.defaults.font
	local scale = style.text_scale or context.defaults.text_scale

	set_text(node, applied, text)
	set_font(node, applied, font)
	set_scale(node, applied, scale)

	local metrics = gui.get_size(node)
	local scale_number = type(scale) == "number" and scale or scale.x
	return metrics.x * scale_number, metrics.y * scale_number
end

function M.prepare(context)
	for index = 2, context.command_count do
		local command = context.commands[index]
		local widget = ensure_widget(context, command)

		if command.kind == "text" then
			local width, height = prepare_text(
				context,
				command,
				widget.nodes.label,
				widget.applied.label,
				command.text
			)
			command.intrinsic_width = width
			command.intrinsic_height = height
		elseif command.kind == "button" then
			local width, height = prepare_text(
				context,
				command,
				widget.nodes.label,
				widget.applied.label,
				command.text
			)
			local padding_x = command.style.padding_x or context.defaults.button_padding_x
			local padding_y = command.style.padding_y or context.defaults.button_padding_y
			command.label_width = width
			command.label_height = height
			command.intrinsic_width = width + padding_x * 2
			command.intrinsic_height = height + padding_y * 2
		elseif command.kind == "box" then
			command.intrinsic_width = 0
			command.intrinsic_height = 0
		elseif command.kind == "spacer" then
			command.intrinsic_width = type(command.style.width) == "number" and command.style.width or 0
			command.intrinsic_height = type(command.style.height) == "number" and command.style.height or 0
		elseif command.kind == "scroll" then
			command.intrinsic_width = 0
			command.intrinsic_height = 0
		end
	end
end

local function desired_parent_id(command)
	if command.kind == "scroll" then
		return command.outer_clip_id
	end
	return command.clip_id
end

local function get_parent_node(context, command)
	local parent_id = desired_parent_id(command)
	if not parent_id then
		return nil, nil
	end

	local parent_widget = context.widgets[parent_id]
	local state = context.scroll_states[parent_id]
	if not parent_widget or not parent_widget.nodes.clipper or not state then
		return nil, nil
	end

	return parent_widget.nodes.clipper, state
end

local function set_parent(node, applied, parent)
	if applied.parent ~= parent then
		gui.set_parent(node, parent, false)
		applied.parent = parent
		applied.x = nil
		applied.y = nil
	end
end

local function set_position(node, applied, x, y, parent_state)
	local local_x = x
	local local_y = y

	if parent_state then
		-- Scroll clipping nodes use PIVOT_SW, so child positions
		-- are relative to the viewport's bottom-left corner.
		local parent_left = parent_state.viewport_x

		local parent_bottom =
		parent_state.viewport_y
		- parent_state.viewport_height

		local_x = x - parent_left
		local_y = y - parent_bottom
	end

	if applied.x ~= local_x or applied.y ~= local_y then
		gui.set_position(
			node,
			vmath.vector3(local_x, local_y, 0)
		)

		applied.x = local_x
		applied.y = local_y
	end
end

local function set_size(node, applied, width, height)
	if applied.width ~= width or applied.height ~= height then
		gui.set_size(node, vmath.vector3(width, height, 0))
		applied.width = width
		applied.height = height
	end
end

local function set_color(node, applied, color)
	if not vector4_equal(applied.color, color) then
		gui.set_color(node, color)
		applied.color = vmath.vector4(color)
	end
end

local function set_visible(node, applied, visible)
	if applied.visible ~= visible then
		gui.set_visible(node, visible)
		applied.visible = visible
	end
end

local function set_enabled(node, applied, enabled)
	if applied.enabled ~= enabled then
		gui.set_enabled(node, enabled)
		applied.enabled = enabled
	end
end

local function set_layer(node, applied, layer)
	if layer and applied.layer ~= layer then
		gui.set_layer(node, layer)
		applied.layer = layer
	end
end

local function set_texture(node, applied, texture, animation)
	if texture and applied.texture ~= texture then
		gui.set_texture(node, texture)
		applied.texture = texture
	end

	if animation and applied.animation ~= animation then
		gui.play_flipbook(node, animation)
		applied.animation = animation
	end
end

local function get_render_group(groups, parent)
	local key = parent or ROOT_GROUP
	local group = groups[key]
	if not group then
		group = {
			parent = parent,
			nodes = {},
			count = 0,
		}
		groups[key] = group
	end
	return group, key
end

local function append_render_node(context, node, parent)
	local group = get_render_group(context.current_render_groups, parent)
	group.count = group.count + 1
	group.nodes[group.count] = node
end

local function apply_drag_preview(context)
	local drag =
		context.drag_state

	local nodes =
		ensure_drag_preview(context)

	if not drag
		or not drag.active
		or not drag.preview
	then
		gui.set_visible(
			nodes.background,
			false
		)

		gui.set_visible(
			nodes.label,
			false
		)

		gui.set_enabled(
			nodes.background,
			false
		)

		gui.set_enabled(
			nodes.label,
			false
		)

		return
	end

	local preview =
		drag.preview

	local width =
		preview.width
		or context.defaults.drag_preview_width

	local height =
		preview.height
		or context.defaults.drag_preview_height

	local offset_x =
		preview.offset_x
		or context.defaults.drag_preview_offset_x

	local offset_y =
		preview.offset_y
		or context.defaults.drag_preview_offset_y

	-- Our UI coordinates are top-left oriented.
	local x =
		drag.x + offset_x

	local y =
		drag.y - offset_y

	local background_color =
		preview.background_color
		or context.defaults.drag_preview_background_color

	if drag.target_id
		and preview.valid_target_color
	then
		background_color = preview.valid_target_color
	end

	local text_color =
		preview.text_color
		or context.defaults.drag_preview_text_color

	-- --------------------------------------------------------
	-- Background
	-- --------------------------------------------------------

	gui.set_position(
		nodes.background,
		vmath.vector3(
			x,
			y,
			0
		)
	)

	gui.set_size(
		nodes.background,
		vmath.vector3(
			width,
			height,
			0
		)
	)

	gui.set_color(
		nodes.background,
		background_color
	)

	gui.set_visible(
		nodes.background,
		true
	)

	gui.set_enabled(
		nodes.background,
		true
	)

	-- --------------------------------------------------------
	-- Text
	-- --------------------------------------------------------

	gui.set_text(
		nodes.label,
		preview.text or ""
	)

	gui.set_position(
		nodes.label,
		vmath.vector3(
			x + width * 0.5,
			y - height * 0.5,
			0
		)
	)

	gui.set_color(
		nodes.label,
		text_color
	)

	if preview.font then
		gui.set_font(
			nodes.label,
			preview.font
		)
	elseif context.defaults.font then
		gui.set_font(
			nodes.label,
			context.defaults.font
		)
	end

	gui.set_visible(
		nodes.label,
		true
	)

	gui.set_enabled(
		nodes.label,
		true
	)

	-- Keep the ghost above the normal UI.
	--
	-- This runs AFTER the normal root render-order pass.
	gui.move_above(
		nodes.background,
		nil
	)

	if context.top_root_node then
		gui.move_above(
			nodes.background,
			context.top_root_node
		)
	end

	gui.move_above(
		nodes.label,
		nodes.background
	)
end

local function apply_box(context, command, node, applied, color)
	local style = command.style
	local visible = style.visible ~= false
	local enabled = style.enabled ~= false
	local parent, parent_state = get_parent_node(context, command)

	set_parent(node, applied, parent)
	set_position(node, applied, command.layout_x, command.layout_y, parent_state)
	set_size(node, applied, command.layout_width, command.layout_height)
	set_color(node, applied, color)
	set_visible(node, applied, visible)
	set_enabled(node, applied, enabled)
	set_layer(node, applied, style.layer)
	set_texture(node, applied, style.texture, style.animation)
	append_render_node(context, node, parent)
end

local function apply_text(context, command, node, applied)
	local style = command.style
	local color = style.color or context.defaults.text_color
	local visible = style.visible ~= false
	local enabled = style.enabled ~= false
	local parent, parent_state = get_parent_node(context, command)

	set_parent(node, applied, parent)
	set_position(node, applied, command.layout_x, command.layout_y, parent_state)
	set_size(node, applied, command.layout_width, command.layout_height)
	set_color(node, applied, color)
	set_visible(node, applied, visible)
	set_enabled(node, applied, enabled)
	set_layer(node, applied, style.layer)

	local line_break = style.line_break == true
	if applied.line_break ~= line_break then
		gui.set_line_break(node, line_break)
		applied.line_break = line_break
	end

	append_render_node(context, node, parent)
end

local function apply_button(context, command, widget)
	local style = command.style
	local hovered = context.hovered_id == command.id
	local pressed = context.active_id == command.id and hovered
	local color = style.background_color or context.defaults.button_color
	local parent, parent_state = get_parent_node(context, command)

	if pressed then
		color = style.pressed_color or context.defaults.button_pressed_color
	elseif hovered then
		color = style.hover_color or context.defaults.button_hover_color
	end

	local background = widget.nodes.background
	local background_applied = widget.applied.background
	local visible = style.visible ~= false
	local enabled = style.enabled ~= false

	set_parent(background, background_applied, parent)
	set_position(background, background_applied, command.layout_x, command.layout_y, parent_state)
	set_size(background, background_applied, command.layout_width, command.layout_height)
	set_color(background, background_applied, color)
	set_visible(background, background_applied, visible)
	set_enabled(background, background_applied, enabled)
	set_layer(background, background_applied, style.layer)
	set_texture(background, background_applied, style.texture, style.animation)
	append_render_node(context, background, parent)

	if command.id == "screen/inventory_scroll/slots/item:1" then
		local local_position = gui.get_position(background)
		local screen_position = gui.get_screen_position(background)

		print("FIRST SLOT")
		print("layout:", command.layout_x, command.layout_y)
		print("local:", local_position.x, local_position.y)
		print("screen:", screen_position.x, screen_position.y)
		print(
		"expected local:",
		command.layout_x - parent_state.viewport_x,
		command.layout_y - parent_state.viewport_y
	)
	print(
		"viewport:",
		parent_state.viewport_x,
		parent_state.viewport_y,
		parent_state.viewport_width,
		parent_state.viewport_height
	)
	end

	local label = widget.nodes.label
	local applied = widget.applied.label
	local text_color = style.text_color or context.defaults.button_text_color
	local center_x = command.layout_x + command.layout_width * 0.5
	local center_y = command.layout_y - command.layout_height * 0.5

	set_parent(label, applied, parent)
	set_position(label, applied, center_x, center_y, parent_state)
	set_size(label, applied, command.layout_width, command.layout_height)
	set_color(label, applied, text_color)
	set_visible(label, applied, visible)
	set_enabled(label, applied, enabled)
	set_layer(label, applied, style.text_layer or style.layer)
	append_render_node(context, label, parent)
end

local function apply_scroll(context, command, widget)
	local style = command.style
	local state = command.scroll_state

	local visible = style.visible ~= false

	local enabled = style.enabled ~= false

	local parent, parent_state =
		get_parent_node(context, command)

	-- ---------------------------------------------------------
	-- Clipping viewport
	-- ---------------------------------------------------------

	local clipper =
		widget.nodes.clipper

	local clipper_applied =
		widget.applied.clipper

	local clipping_visible =
		style.background_color ~= nil
		or style.texture ~= nil

	local clipper_color =
		style.background_color
		or vmath.vector4(1, 1, 1, 1)

	local clipper_x =
		command.layout_x

	local clipper_y =
		command.layout_y
		- command.layout_height

	set_parent(
		clipper,
		clipper_applied,
		parent
	)

	set_position(
		clipper,
		clipper_applied,
		clipper_x,
		clipper_y,
		parent_state
	)

	set_size(
		clipper,
		clipper_applied,
		command.layout_width,
		command.layout_height
	)

	set_color(
		clipper,
		clipper_applied,
		clipper_color
	)

	set_visible(
		clipper,
		clipper_applied,
		visible
	)

	set_enabled(
		clipper,
		clipper_applied,
		enabled
	)

	set_layer(
		clipper,
		clipper_applied,
		style.layer
	)

	set_texture(
		clipper,
		clipper_applied,
		style.texture,
		style.animation
	)

	if clipper_applied.clipping_visible ~= clipping_visible then
		gui.set_clipping_visible(
			clipper,
			clipping_visible
		)

		clipper_applied.clipping_visible = clipping_visible
	end

	append_render_node(
		context,
		clipper,
		parent
	)

	-- ---------------------------------------------------------
	-- Scrollbar
	-- ---------------------------------------------------------

	local scrollbar_visible =
		visible
		and enabled
		and state.scrollbar_visible

	local track =
		widget.nodes.scrollbar_track

	local track_applied =
		widget.applied.scrollbar_track

	local track_color =
		style.scrollbar_track_color
		or context.defaults.scrollbar_track_color

	set_parent(
		track,
		track_applied,
		parent
	)

	set_position(
		track,
		track_applied,
		state.scrollbar_track_x,
		state.scrollbar_track_y,
		parent_state
	)

	set_size(
		track,
		track_applied,
		state.scrollbar_track_width,
		state.scrollbar_track_height
	)

	set_color(
		track,
		track_applied,
		track_color
	)

	set_visible(
		track,
		track_applied,
		scrollbar_visible
	)

	set_enabled(
		track,
		track_applied,
		scrollbar_visible
	)

	set_layer(
		track,
		track_applied,
		style.scrollbar_layer or style.layer
	)

	append_render_node(
		context,
		track,
		parent
	)

	local thumb =
		widget.nodes.scrollbar_thumb

	local thumb_applied =
		widget.applied.scrollbar_thumb

	local thumb_color =
		style.scrollbar_thumb_color
		or context.defaults.scrollbar_thumb_color

	if context.scrollbar_drag_id == command.id then
		thumb_color =
			style.scrollbar_thumb_pressed_color
			or context.defaults
			.scrollbar_thumb_pressed_color
			elseif context.hovered_scrollbar_id
			== command.id
	then
		thumb_color =
			style.scrollbar_thumb_hover_color
			or context.defaults
			.scrollbar_thumb_hover_color
	end

	set_parent(
		thumb,
		thumb_applied,
		parent
	)

	set_position(
		thumb,
		thumb_applied,
		state.scrollbar_thumb_x,
		state.scrollbar_thumb_y,
		parent_state
	)

	set_size(
		thumb,
		thumb_applied,
		state.scrollbar_thumb_width,
		state.scrollbar_thumb_height
	)

	set_color(
		thumb,
		thumb_applied,
		thumb_color
	)

	set_visible(
		thumb,
		thumb_applied,
		scrollbar_visible
	)

	set_enabled(
		thumb,
		thumb_applied,
		scrollbar_visible
	)

	set_layer(
		thumb,
		thumb_applied,
		style.scrollbar_layer or style.layer
	)

	append_render_node(context, thumb, parent)
end

local function clear_render_node_list(context)
	for index = 1, context.current_render_node_count do
		context.current_render_nodes[index] = nil
	end

	context.current_render_node_count = 0
end

local function flatten_render_group(context, group)
	if not group then
		return
	end

	for index = 1, group.count do
		local node = group.nodes[index]

		context.current_render_node_count =
		context.current_render_node_count + 1

		context.current_render_nodes[
		context.current_render_node_count
		] = node

		-- A clipping node's children must appear immediately
		-- after the clipping node in the flattened render order.
		local child_group =
		context.current_render_groups[node]

		if child_group then
			flatten_render_group(context, child_group)
		end
	end
end

local function render_order_changed(context)
	if context.current_render_node_count
	~= context.last_render_node_count
	then
		return true
	end

	for index = 1, context.current_render_node_count do
		if context.current_render_nodes[index]
		~= context.last_render_nodes[index]
		then
			return true
		end
	end

	return false
end

local function save_render_order(context)
	for index = 1, context.last_render_node_count do
		context.last_render_nodes[index] = nil
	end

	for index = 1, context.current_render_node_count do
		context.last_render_nodes[index] =
		context.current_render_nodes[index]
	end

	context.last_render_node_count =
	context.current_render_node_count
end

local function apply_render_order(context)
	local root_group =
		context.current_render_groups[ROOT_GROUP]

	context.top_root_node = nil

	if not root_group
		or root_group.count == 0
	then
		return
	end

	gui.move_below(
		root_group.nodes[1],
		nil
	)

	for index = 2, root_group.count do
		gui.move_above(
			root_group.nodes[index],
			root_group.nodes[index - 1]
		)
	end

	context.top_root_node =
		root_group.nodes[root_group.count]
end

local function clear_current_render_groups(context)
	for key, group in pairs(context.current_render_groups) do
		for index = 1, group.count do
			group.nodes[index] = nil
		end
		context.current_render_groups[key] = nil
	end
end

local function remove_stale_widgets(context)
	context.stale_id_count = 0

	for id, widget in pairs(context.widgets) do
		if widget.last_seen_frame ~= context.frame then
			context.stale_id_count = context.stale_id_count + 1
			context.stale_ids[context.stale_id_count] = id
		end
	end

	-- Detach first. Deleting a clipping node recursively deletes its children,
	-- and those children are owned by separate retained widget records.
	for index = 1, context.stale_id_count do
		local widget = context.widgets[context.stale_ids[index]]
		detach_nodes(widget)
	end

	for index = 1, context.stale_id_count do
		local id = context.stale_ids[index]
		local widget = context.widgets[id]
		delete_nodes(widget)
		context.widgets[id] = nil
		context.scroll_states[id] = nil
		context.stale_ids[index] = nil

		if context.hovered_id == id then
			context.hovered_id = nil
		end
		if context.active_id == id then
			context.active_id = nil
		end
		if context.drag_scroll_id == id then
			context.drag_scroll_id = nil
		end
		if context.drag_scroll_candidate_id == id then
			context.drag_scroll_candidate_id = nil
		end
		if context.scrollbar_drag_id == id then
			context.scrollbar_drag_id = nil
		end
		if context.hovered_scrollbar_id == id then
			context.hovered_scrollbar_id = nil
		end
	end
end

function M.apply(context)
	clear_current_render_groups(context)

	for index = 2, context.command_count do
		local command = context.commands[index]
		local widget = command.widget

		if command.kind == "scroll" then
			apply_scroll(context, command, widget)
		elseif command.kind == "container" and widget.shape == "box" then
			local color = command.style.background_color or vmath.vector4(1, 1, 1, 1)
			apply_box(context, command, widget.nodes.background, widget.applied.background, color)
		elseif command.kind == "box" then
			local color = command.style.background_color or vmath.vector4(1, 1, 1, 1)
			apply_box(context, command, widget.nodes.background, widget.applied.background, color)
		elseif command.kind == "text" then
			apply_text(context, command, widget.nodes.label, widget.applied.label)
		elseif command.kind == "button" then
			apply_button(context, command, widget)
		end
	end

	remove_stale_widgets(context)

	apply_render_order(context)

	-- Must happen after normal UI ordering.
	apply_drag_preview(context)
end

function M.destroy(context)
	for _, widget in pairs(context.widgets) do
		detach_nodes(widget)
	end
	for _, widget in pairs(context.widgets) do
		delete_nodes(widget)
	end
	context.widgets = {}
	context.scroll_states = {}
	context.last_render_groups = {}
	context.current_render_groups = {}

	if context.drag_preview_nodes then
		if context.drag_preview_nodes.background then
			gui.delete_node(
				context.drag_preview_nodes.background
			)
		end

		if context.drag_preview_nodes.label then
			gui.delete_node(
				context.drag_preview_nodes.label
			)
		end

		context.drag_preview_nodes = nil
	end
end

return M
