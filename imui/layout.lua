local M = {}

local function number_or(value, fallback)
	if type(value) == "number" then
		return value
	end
	return fallback
end

local function padding(style)
	local all = number_or(style.padding, 0)
	local horizontal = number_or(style.padding_x, all)
	local vertical = number_or(style.padding_y, all)

	return {
		left = number_or(style.padding_left, horizontal),
		right = number_or(style.padding_right, horizontal),
		top = number_or(style.padding_top, vertical),
		bottom = number_or(style.padding_bottom, vertical),
	}
end

local function clamp(value, minimum, maximum)
	if minimum and value < minimum then
		value = minimum
	end
	if maximum and value > maximum then
		value = maximum
	end
	return value
end

local function clamp_size(value, minimum, maximum)
	return clamp(value, minimum, maximum)
end

local function resolve_requested_size(requested, content, available)
	if type(requested) == "number" then
		return requested
	end

	if requested == "fill" and available then
		return available
	end

	return content
end

local function resolved_outer_available(requested, available)
	if type(requested) == "number" then
		return requested
	end
	if requested == "fill" then
		return available
	end
	return available
end

local function is_container(command)
	return command.kind == "root" or command.kind == "container" or command.kind == "scroll"
end

local function gap_values(style)
	local gap = number_or(style.gap, 0)
	return number_or(style.column_gap, gap), number_or(style.row_gap, gap)
end

local measure

local function measure_leaf(command, available_width, available_height)
	local style = command.style
	local width = resolve_requested_size(style.width, command.intrinsic_width, available_width)
	local height = resolve_requested_size(style.height, command.intrinsic_height, available_height)

	command.measured_width = clamp_size(width, style.min_width, style.max_width)
	command.measured_height = clamp_size(height, style.min_height, style.max_height)
	return command.measured_width, command.measured_height
end

local function measure_grid(command, available_width, available_height)
	local style = command.style
	local edges = padding(style)
	local outer_available_width = resolved_outer_available(style.width, available_width)
	local outer_available_height = resolved_outer_available(style.height, available_height)
	local inner_available_width = outer_available_width and math.max(0, outer_available_width - edges.left - edges.right) or nil
	local inner_available_height = outer_available_height and math.max(0, outer_available_height - edges.top - edges.bottom) or nil
	local columns = math.max(1, math.floor(number_or(style.columns, 1)))
	local column_gap, row_gap = gap_values(style)
	local requested_cell_width = type(style.cell_width) == "number" and style.cell_width or nil
	local requested_cell_height = type(style.cell_height) == "number" and style.cell_height or nil
	local cell_width = requested_cell_width
	local cell_height = requested_cell_height

	if not cell_width and inner_available_width then
		cell_width = math.max(0, (inner_available_width - column_gap * (columns - 1)) / columns)
	end

	local max_child_width = 0
	local max_child_height = 0
	for index = 1, command.child_count do
		local child = command.children[index]
		local child_width, child_height = measure(child, cell_width, cell_height)
		max_child_width = math.max(max_child_width, child_width)
		max_child_height = math.max(max_child_height, child_height)
	end

	cell_width = cell_width or max_child_width
	cell_height = cell_height or max_child_height

	local rows = command.child_count == 0 and 0 or math.ceil(command.child_count / columns)
	local content_width = columns * cell_width + math.max(0, columns - 1) * column_gap
	local content_height = rows * cell_height + math.max(0, rows - 1) * row_gap
	content_width = content_width + edges.left + edges.right
	content_height = content_height + edges.top + edges.bottom

	local width = resolve_requested_size(style.width, content_width, available_width)
	local height = resolve_requested_size(style.height, content_height, available_height)

	command.grid_columns = columns
	command.grid_rows = rows
	command.grid_cell_width = cell_width
	command.grid_cell_height = cell_height
	command.grid_column_gap = column_gap
	command.grid_row_gap = row_gap
	command.content_width = content_width
	command.content_height = content_height
	command.measured_width = clamp_size(width, style.min_width, style.max_width)
	command.measured_height = clamp_size(height, style.min_height, style.max_height)
	return command.measured_width, command.measured_height
end

local function measure_children_linear(command, direction, inner_available_width, inner_available_height)
	local style = command.style
	local gap = number_or(style.gap, 0)
	local content_width = 0
	local content_height = 0

	for index = 1, command.child_count do
		local child = command.children[index]
		local child_available_width = inner_available_width
		local child_available_height = inner_available_height

		if direction == "column" then
			child_available_height = nil
		elseif direction == "row" then
			child_available_width = nil
		end

		local child_width, child_height = measure(child, child_available_width, child_available_height)

		if direction == "column" then
			content_width = math.max(content_width, child_width)
			content_height = content_height + child_height
		elseif direction == "row" then
			content_width = content_width + child_width
			content_height = math.max(content_height, child_height)
		else
			content_width = math.max(content_width, child_width)
			content_height = math.max(content_height, child_height)
		end
	end

	if command.child_count > 1 and direction ~= "overlay" then
		if direction == "column" then
			content_height = content_height + gap * (command.child_count - 1)
		else
			content_width = content_width + gap * (command.child_count - 1)
		end
	end

	return content_width, content_height
end

local function measure_scroll(command, available_width, available_height)
	local style = command.style
	local edges = padding(style)
	local outer_available_width = resolved_outer_available(style.width, available_width)
	local outer_available_height = resolved_outer_available(style.height, available_height)
	local inner_available_width = outer_available_width and math.max(0, outer_available_width - edges.left - edges.right) or nil
	local inner_available_height = outer_available_height and math.max(0, outer_available_height - edges.top - edges.bottom) or nil
	local axis = command.scroll_axis or "vertical"
	local direction = command.content_direction or (axis == "horizontal" and "row" or "column")
	local child_available_width = inner_available_width
	local child_available_height = inner_available_height

	if axis == "vertical" then
		child_available_height = nil
	elseif axis == "horizontal" then
		child_available_width = nil
	elseif axis == "both" then
		child_available_width = nil
		child_available_height = nil
	end

	local content_width, content_height = measure_children_linear(
		command,
		direction,
		child_available_width,
		child_available_height
	)

	local total_content_width = content_width + edges.left + edges.right
	local total_content_height = content_height + edges.top + edges.bottom
	local width = resolve_requested_size(style.width, total_content_width, available_width)
	local height = resolve_requested_size(style.height, total_content_height, available_height)

	command.content_width = content_width
	command.content_height = content_height
	command.measured_width = clamp_size(width, style.min_width, style.max_width)
	command.measured_height = clamp_size(height, style.min_height, style.max_height)
	return command.measured_width, command.measured_height
end

local function measure_container(command, available_width, available_height)
	local style = command.style
	local direction = command.direction or "overlay"

	if direction == "grid" then
		return measure_grid(command, available_width, available_height)
	end

	local edges = padding(style)
	local outer_available_width = resolved_outer_available(style.width, available_width)
	local outer_available_height = resolved_outer_available(style.height, available_height)
	local inner_available_width = outer_available_width and math.max(0, outer_available_width - edges.left - edges.right) or nil
	local inner_available_height = outer_available_height and math.max(0, outer_available_height - edges.top - edges.bottom) or nil
	local content_width, content_height = measure_children_linear(
		command,
		direction,
		inner_available_width,
		inner_available_height
	)

	content_width = content_width + edges.left + edges.right
	content_height = content_height + edges.top + edges.bottom

	local width = resolve_requested_size(style.width, content_width, available_width)
	local height = resolve_requested_size(style.height, content_height, available_height)

	command.content_width = content_width
	command.content_height = content_height
	command.measured_width = clamp_size(width, style.min_width, style.max_width)
	command.measured_height = clamp_size(height, style.min_height, style.max_height)
	return command.measured_width, command.measured_height
end

measure = function(command, available_width, available_height)
	if not is_container(command) then
		return measure_leaf(command, available_width, available_height)
	end

	if command.kind == "scroll" then
		return measure_scroll(command, available_width, available_height)
	end

	return measure_container(command, available_width, available_height)
end

local function child_cross_size(child, direction, available, align)
	local style = child.style
	local requested = direction == "column" and style.width or style.height
	local measured = direction == "column" and child.measured_width or child.measured_height
	local own_align = style.align_self or align

	if requested == "fill" or own_align == "stretch" then
		return available
	end

	return math.min(measured, available)
end

local function child_main_weight(child, direction)
	local style = child.style
	local requested = direction == "column" and style.height or style.width
	local grow = number_or(style.grow, 0)

	if grow > 0 then
		return grow
	end

	if requested == "fill" then
		return 1
	end

	return 0
end

local function child_main_measured(child, direction)
	if direction == "column" then
		return child.measured_height
	end
	return child.measured_width
end

local function get_offset(alignment, available, child_size)
	if alignment == "center" then
		return (available - child_size) * 0.5
	elseif alignment == "end" then
		return available - child_size
	end
	return 0
end

local arrange

local function arrange_linear(command, direction)
	local style = command.style
	local edges = padding(style)
	local gap = number_or(style.gap, 0)
	local align = style.align_items or "start"
	local justify = style.justify_content or "start"

	local content_x = command.layout_x + edges.left
	local content_y = command.layout_y - edges.top
	local content_width = math.max(0, command.layout_width - edges.left - edges.right)
	local content_height = math.max(0, command.layout_height - edges.top - edges.bottom)
	local available_main = direction == "column" and content_height or content_width
	local available_cross = direction == "column" and content_width or content_height
	local fixed_main = 0
	local total_weight = 0

	for index = 1, command.child_count do
		local child = command.children[index]
		local weight = child_main_weight(child, direction)
		if weight > 0 then
			total_weight = total_weight + weight
		else
			fixed_main = fixed_main + child_main_measured(child, direction)
		end
	end

	local base_gap_total = gap * math.max(0, command.child_count - 1)
	local remaining = math.max(0, available_main - fixed_main - base_gap_total)
	local offset = 0
	local actual_gap = gap

	if total_weight == 0 then
		local used = fixed_main + base_gap_total
		local free = math.max(0, available_main - used)
		if justify == "center" then
			offset = free * 0.5
		elseif justify == "end" then
			offset = free
		elseif justify == "space_between" and command.child_count > 1 then
			actual_gap = gap + free / (command.child_count - 1)
		end
	end

	local cursor_x = content_x + (direction == "row" and offset or 0)
	local cursor_y = content_y - (direction == "column" and offset or 0)

	for index = 1, command.child_count do
		local child = command.children[index]
		local weight = child_main_weight(child, direction)
		local main_size = child_main_measured(child, direction)
		if weight > 0 and total_weight > 0 then
			main_size = remaining * (weight / total_weight)
		end

		local cross_size = child_cross_size(child, direction, available_cross, align)
		local child_align = child.style.align_self or align
		local cross_offset = get_offset(child_align, available_cross, cross_size)

		if direction == "column" then
			arrange(child, content_x + cross_offset, cursor_y, cross_size, main_size)
			cursor_y = cursor_y - main_size - actual_gap
		else
			arrange(child, cursor_x, content_y - cross_offset, main_size, cross_size)
			cursor_x = cursor_x + main_size + actual_gap
		end
	end
end

local function arrange_overlay(command)
	local style = command.style
	local edges = padding(style)
	local content_x = command.layout_x + edges.left
	local content_y = command.layout_y - edges.top
	local content_width = math.max(0, command.layout_width - edges.left - edges.right)
	local content_height = math.max(0, command.layout_height - edges.top - edges.bottom)

	for index = 1, command.child_count do
		local child = command.children[index]
		local child_style = child.style
		local width = child_style.width == "fill" and content_width or math.min(child.measured_width, content_width)
		local height = child_style.height == "fill" and content_height or math.min(child.measured_height, content_height)
		local x = content_x + number_or(child_style.x, 0)
		local y = content_y - number_or(child_style.y, 0)
		arrange(child, x, y, width, height)
	end
end

local function arrange_grid(command)
	local style = command.style
	local edges = padding(style)

	local columns = command.grid_columns
	local column_gap = command.grid_column_gap
	local row_gap = command.grid_row_gap

	local justify_items = style.justify_items or "stretch"
	local align_items = style.align_items or "stretch"

	local content_x =
	command.layout_x + edges.left

	local content_y =
	command.layout_y - edges.top

	local content_width = math.max(
	0,
	command.layout_width
	- edges.left
	- edges.right
)

-- Automatic cell widths must come from the grid's final
-- arranged width. Using the measured cell width here can
-- create a fill-size feedback loop across frames.
local cell_width

if type(style.cell_width) == "number" then
	cell_width = style.cell_width
else
	cell_width = math.max(
	0,
	(
	content_width
	- column_gap * math.max(0, columns - 1)
) / columns
)
end

local cell_height

if type(style.cell_height) == "number" then
cell_height = style.cell_height
else
cell_height = command.grid_cell_height
end

-- Keep these updated so scroll-content calculations and
-- diagnostics reflect the final resolved grid dimensions.
command.grid_cell_width = cell_width
command.grid_cell_height = cell_height

local rows =
command.child_count == 0
and 0
or math.ceil(command.child_count / columns)

command.grid_rows = rows

command.content_width =
edges.left
+ edges.right
+ columns * cell_width
+ math.max(0, columns - 1) * column_gap

command.content_height =
edges.top
+ edges.bottom
+ rows * cell_height
+ math.max(0, rows - 1) * row_gap

for index = 1, command.child_count do
local child = command.children[index]
local zero_index = index - 1

local column =
zero_index % columns

local row =
math.floor(zero_index / columns)

local cell_x =
content_x
+ column * (cell_width + column_gap)

local cell_y =
content_y
- row * (cell_height + row_gap)

local child_justify =
child.style.justify_self
or justify_items

local child_align =
child.style.align_self
or align_items

local width = child.measured_width
local height = child.measured_height

if child.style.width == "fill"
or child_justify == "stretch"
then
width = cell_width
else
width = math.min(
width,
cell_width
)
end

if child.style.height == "fill"
or child_align == "stretch"
then
height = cell_height
else
height = math.min(
height,
cell_height
)
end

local offset_x = get_offset(
child_justify,
cell_width,
width
)

local offset_y = get_offset(
child_align,
cell_height,
height
)

arrange(
child,
cell_x + offset_x,
cell_y - offset_y,
width,
height
)
end
end

local function arrange_scroll_children(command, content_x, content_y, viewport_width, viewport_height)
	local style = command.style
	local direction = command.content_direction or (command.scroll_axis == "horizontal" and "row" or "column")
	local gap = number_or(style.gap, 0)
	local state = command.scroll_state
	local cursor_x = content_x - state.x
	local cursor_y = content_y + state.y

	if direction == "overlay" then
		for index = 1, command.child_count do
			local child = command.children[index]
			local child_style = child.style
			local width = child_style.width == "fill" and viewport_width or child.measured_width
			local height = child_style.height == "fill" and viewport_height or child.measured_height
			arrange(
				child,
				cursor_x + number_or(child_style.x, 0),
				cursor_y - number_or(child_style.y, 0),
				width,
				height
			)
		end
		return
	end

	for index = 1, command.child_count do
		local child = command.children[index]
		if direction == "row" then
			local height = child.style.height == "fill" and viewport_height or child.measured_height
			arrange(child, cursor_x, cursor_y, child.measured_width, height)
			cursor_x = cursor_x + child.measured_width + gap
		else
			local width = child.style.width == "fill" and viewport_width or child.measured_width
			arrange(child, cursor_x, cursor_y, width, child.measured_height)
			cursor_y = cursor_y - child.measured_height - gap
		end
	end
end

local function arrange_scroll(command)
	local style = command.style
	local edges = padding(style)
	local viewport_x = command.layout_x + edges.left
	local viewport_y = command.layout_y - edges.top
	local viewport_width = math.max(0, command.layout_width - edges.left - edges.right)
	local viewport_height = math.max(0, command.layout_height - edges.top - edges.bottom)
	local state = command.scroll_state
	local content_width = math.max(command.content_width, viewport_width)
	local content_height = math.max(command.content_height, viewport_height)

	state.axis = command.scroll_axis or "vertical"
	state.parent_clip_id = command.outer_clip_id
	state.viewport_x = command.layout_x
	state.viewport_y = command.layout_y
	state.viewport_width = command.layout_width
	state.viewport_height = command.layout_height
	state.content_width = content_width
	state.content_height = content_height
	state.max_x = math.max(0, content_width - viewport_width)
	state.max_y = math.max(0, content_height - viewport_height)
	state.x = clamp(state.x, 0, state.max_x)
	state.y = clamp(state.y, 0, state.max_y)

	local supports_vertical_scrollbar =
	state.axis == "vertical"
	or state.axis == "both"

	state.scrollbar_visible =
	state.scrollbar_enabled
	and supports_vertical_scrollbar
	and state.max_y > 0
	and viewport_height > 0

	if state.scrollbar_visible then
		local scrollbar_width =
		state.scrollbar_width

		local scrollbar_margin =
			state.scrollbar_margin

		local track_height = math.max(
			0,
			command.layout_height
			- scrollbar_margin * 2
		)

		local track_x =
		command.layout_x
		+ command.layout_width
		- scrollbar_margin
		- scrollbar_width

		local track_y =
		command.layout_y
		- scrollbar_margin

		local visible_ratio =
		content_height > 0
		and viewport_height / content_height
		or 1

		visible_ratio =
		math.max(
			0,
			math.min(1, visible_ratio)
		)

		local thumb_height = math.max(
			state.scrollbar_min_thumb,
			track_height * visible_ratio
		)

		thumb_height =
		math.min(
			thumb_height,
			track_height
		)

		local thumb_travel =
		math.max(
			0,
			track_height - thumb_height
		)

		local progress =
			state.max_y > 0
			and state.y / state.max_y
			or 0

		state.scrollbar_track_x = track_x

		state.scrollbar_track_y = track_y

		state.scrollbar_track_width = scrollbar_width

		state.scrollbar_track_height = track_height

		state.scrollbar_thumb_x = track_x

		state.scrollbar_thumb_y =
			track_y - thumb_travel * progress

		state.scrollbar_thumb_width = scrollbar_width

		state.scrollbar_thumb_height =
			thumb_height
	else
		state.scrollbar_track_width = 0
		state.scrollbar_track_height = 0
		state.scrollbar_thumb_width = 0
		state.scrollbar_thumb_height = 0
	end

	arrange_scroll_children(command, viewport_x, viewport_y, viewport_width, viewport_height)
end

arrange = function(command, x, y, width, height)
	command.layout_x = x
	command.layout_y = y
	command.layout_width = math.max(0, width)
	command.layout_height = math.max(0, height)

	if not is_container(command) then
		return
	end

	if command.kind == "scroll" then
		arrange_scroll(command)
		return
	end

	local direction = command.direction or "overlay"
	if direction == "column" or direction == "row" then
		arrange_linear(command, direction)
	elseif direction == "grid" then
		arrange_grid(command)
	else
		arrange_overlay(command)
	end
end

function M.compute(context, root)
	local width = gui.get_width()
	local height = gui.get_height()

	root.measured_width = width
	root.measured_height = height

	for index = 1, root.child_count do
		measure(root.children[index], width, height)
	end

	arrange(root, 0, height, width, height)
end

return M
