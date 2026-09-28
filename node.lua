-- Copyright (C) 2016-2019 Florian Wesch <fw@info-beamer.com>

gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

util.no_globals()

local json = require "json"
local matrix = require "matrix2d"

local font = resource.load_font "font.ttf"
local black = resource.create_colored_texture(0, 0, 0, 1)
local badge_blue = resource.create_colored_texture(2/255, 122/255, 193/255, 1)
local badge_green = resource.create_colored_texture(0.02, 0.55, 0.18, 1)
local badge_3d = resource.load_image "3D.png"
local route_blue = resource.create_colored_texture(0.02, 0.36, 0.86, 1)
local seat_blue = resource.create_colored_texture(0.18, 0.43, 0.82, 1)
local seat_fill = resource.create_colored_texture(0.035, 0.055, 0.09, 1)
local warning_red = resource.create_colored_texture(0.82, 0.16, 0.18, 1)

local indy_id
local screen = {name = ""}
local local_time = ""

local border
local st, vid_scaler
local portrait, rotation, main_logo, main_logo_name, corner_logo
local debug = true
local outdated = false
local layout = {}
local seat_navigation = {active = false}
local seat_navigation_started = 0

local my_serial = sys.get_env "SERIAL"
local scale = 1

local REF_W, REF_H = 1920, 1080

local function scale_x(x)
    return x * WIDTH / REF_W
end

local function scale_y(y)
    return y * HEIGHT / REF_H
end

local function scale_s(s)
    return s * math.min(WIDTH / REF_W, HEIGHT / REF_H)
end

local function compute_layout()
    layout.poster_y = scale_y(56)
    layout.poster_h = scale_y(700)
    layout.poster_pad = scale_x(4)
    layout.poster_x1 = layout.poster_pad
    layout.poster_x2 = WIDTH - layout.poster_pad
    layout.poster_y2 = layout.poster_y + layout.poster_h
    layout.badge_h = scale_y(117)
    layout.badge_w = scale_x(572)
    layout.badge_y = scale_y(28)
    layout.movie_y = scale_y(780)
    layout.screen_y = scale_y(860)
    layout.bottom_y = scale_y(960)
    -- Size off the shorter side so portrait stays readable
    local short = math.min(WIDTH, HEIGHT)
    layout.corner_size = short * 0.18
    layout.badge_3d_size = short * 0.09
    layout.badge_size = scale_s(76.8)
    if portrait then
        layout.title_size = short * 0.08
    else
        layout.title_size = scale_s(64)
    end
    layout.bottom_size = short * 0.048
end

local function fit_text(text, max_size, max_width, min_size)
    min_size = min_size or 16
    local size = max_size
    while size > min_size do
        if font:width(text, size) <= max_width then
            return size
        end
        size = size - 2
    end
    return min_size
end

local function draw_centered_text(text, y, size, max_width)
    size = fit_text(text, size, max_width, 16)
    local w = font:width(text, size)
    font:write((WIDTH - w) / 2, y, text, size, 1, 1, 1, 1)
end

local function draw_badge(text, upcoming)
    if not text or text == "" then
        return
    end

    local size = fit_text(text, layout.badge_size, layout.badge_w - scale_x(40), 20)
    local text_w = font:width(text, size)
    local pad_x = scale_x(28)
    local pad_y = scale_y(18)
    local box_w = math.min(layout.badge_w, text_w + pad_x * 2)
    local box_h = math.max(layout.badge_h, size + pad_y * 2)
    local x1 = (WIDTH - box_w) / 2
    local y1 = layout.badge_y
    local fill = upcoming and badge_green or badge_blue

    fill:draw(x1, y1, x1 + box_w, y1 + box_h)
    font:write(x1 + (box_w - text_w) / 2, y1 + pad_y, text, size, 1, 1, 1, 1)
end

local function draw_title_row(show)
    local title = show.name or ""
    local size = layout.title_size
    local max_w = WIDTH - scale_x(40)
    local gap = scale_x(20)
    local badge_w, badge_h = 0, 0

    if show.is_3d and badge_3d then
        local bw, bh = badge_3d:size()
        badge_h = layout.badge_3d_size
        badge_w = badge_h * (bw / math.max(bh, 1))
        if badge_w > WIDTH * 0.22 then
            badge_w = WIDTH * 0.22
            badge_h = badge_w * (bh / math.max(bw, 1))
        end
        max_w = max_w - badge_w - gap
    end

    size = fit_text(title, size, max_w, 16)
    local text_w = font:width(title, size)
    local total_w = text_w
    if badge_w > 0 then
        total_w = total_w + gap + badge_w
    end

    local x = (WIDTH - total_w) / 2
    local y = layout.movie_y

    if badge_w > 0 then
        local bw, bh = badge_3d:size()
        local iy = y + (size - badge_h) / 2
        local ix1, iy1, ix2, iy2 = util.scale_into(badge_w, badge_h, bw, bh)
        badge_3d:draw(x + ix1, iy + iy1, x + ix2, iy + iy2)
        x = x + badge_w + gap
    end

    font:write(x, y, title, size, 1, 1, 1, 1)
end

local function draw_show_info()
    if not screen.show then
        return
    end
    draw_badge(screen.show.status_label, screen.show.upcoming)
    draw_title_row(screen.show)
    draw_centered_text((screen.name or ""):upper(), layout.screen_y, layout.bottom_size, WIDTH - scale_x(40))
    draw_bottom_bar(screen.show)
end

local function draw_bottom_bar(show)
    if not show then
        return
    end

    local show_time = (show.start or ""):upper()
    local y = layout.bottom_y

    if main_logo then
        local size = layout.corner_size
        local lx1 = scale_x(8)
        local ly2 = HEIGHT - scale_y(8)
        local ly1 = ly2 - size
        local lw, lh = main_logo:size()
        local ix1, iy1, ix2, iy2 = util.scale_into(size, size, lw, lh)
        main_logo:draw(lx1 + ix1, ly1 + iy1, lx1 + ix2, ly1 + iy2)
        y = ly1 + (size - layout.bottom_size) / 2
    elseif corner_logo then
        local size = layout.corner_size
        local lx1 = scale_x(8)
        local ly2 = HEIGHT - scale_y(8)
        local ly1 = ly2 - size
        local lw, lh = corner_logo:size()
        local ix1, iy1, ix2, iy2 = util.scale_into(size, size, lw, lh)
        corner_logo:draw(lx1 + ix1, ly1 + iy1, lx1 + ix2, ly1 + iy2)
        y = ly1 + (size - layout.bottom_size) / 2
    end

    local time_label = "Show time: " .. show_time
    local time_w = font:width(time_label, layout.bottom_size)
    font:write(WIDTH - time_w - scale_x(40), y, time_label, layout.bottom_size, 1, 1, 1, 1)
end

util.file_watch("border.glsl", function(raw)
    border = resource.create_shader(raw)
end)

util.file_watch("config.json", function(raw)
    local config = json.decode(raw)
    pp(config)

    debug = false

    indy_id = nil
    rotation = 0
    main_logo_name = config.main_logo.asset_name
    main_logo = resource.load_image(config.main_logo.asset_name)
    corner_logo = resource.load_image(config.corner_logo.asset_name)

    for idx = 1, #config.signs do
        local sign = config.signs[idx]
        if sign.serial == my_serial then
            indy_id = sign.indy_id
            rotation = sign.rotation
            debug = sign.debug
        end
    end
    print("my screen indy id is " .. tostring(indy_id))

    gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)
    st = util.screen_transform(rotation)
    print("screen size is " .. WIDTH .. "x" .. HEIGHT)

    vid_scaler = matrix.trans(NATIVE_WIDTH/2, NATIVE_HEIGHT/2) *
                 matrix.scale(scale, scale) *
                 matrix.trans(-NATIVE_WIDTH/2, -NATIVE_HEIGHT/2)

    portrait = rotation == 90 or rotation == 270
    compute_layout()
end)

util.json_watch("screen.json", function(new_screen)
    screen = new_screen
end)

util.json_watch("seat_nav_runtime.json", function(new_navigation)
    seat_navigation = new_navigation or {active = false}
    seat_navigation_started = sys.now()
end)

util.data_mapper{
    ["time/set"] = function(new_local_time)
        local_time = new_local_time
    end;
}

local function get_assets()
    if not screen.show then
        return {{
            media = {
                asset_name = main_logo_name,
                type = "fallback",
            },
            duration = 5
        }}
    end

    return {{
        media = {
            asset_name = screen.show.poster_file,
            type = screen.show.media_type or "image",
        },
        duration = 86400
    }}
end

local function fitted_poster_rect(media_w, media_h)
    local area_x1, area_y1 = layout.poster_x1, layout.poster_y
    local area_w = layout.poster_x2 - layout.poster_x1
    local area_h = layout.poster_y2 - layout.poster_y
    local ix1, iy1, ix2, iy2 = util.scale_into(area_w, area_h, media_w, media_h)
    return area_x1 + ix1, area_y1 + iy1, area_x1 + ix2, area_y1 + iy2
end

local function draw_hugged_poster(media_w, media_h, draw_media)
    local x1, y1, x2, y2 = fitted_poster_rect(media_w, media_h)
    local border_color = {0.45, 0.78, 1.0, 1.0}
    if screen.show and screen.show.color then
        border_color = screen.show.color
    end
    border:use{
        size = {media_w, media_h},
        radius = scale_s(22),
        border = scale_x(8),
        borderColor = border_color,
        time = 0,
    }
    draw_media(x1, y1, x2, y2)
    border:deactivate()
end

local function Fallback(asset_name, duration)
    local obj = resource.load_image(asset_name)
    local started

    local function start()
        started = sys.now()
    end
    local function draw()
        local w, h = obj:size()
        local max_w = scale_x(500)
        local max_h = scale_y(220)
        local box_x = (WIDTH - max_w) / 2
        local box_y = (HEIGHT - max_h) / 2
        black:draw(0, 0, WIDTH, HEIGHT)
        local x1, y1, x2, y2 = util.scale_into(max_w, max_h, w, h)
        obj:draw(box_x + x1, box_y + y1, box_x + x2, box_y + y2)
        return sys.now() - started > duration
    end
    local function unload()
        obj:dispose()
    end
    return {
        start = start;
        draw = draw;
        unload = unload;
    }
end

local function Image(asset_name, duration)
    print("started new image " .. asset_name)
    local obj = resource.load_image(asset_name)
    local started

    local function start()
        started = sys.now()
    end
    local function draw()
        black:draw(0, 0, WIDTH, HEIGHT)

        local w, h = obj:size()
        draw_hugged_poster(w, h, function(x1, y1, x2, y2)
            obj:draw(x1, y1, x2, y2)
        end)

        if screen.show then
            draw_show_info()
        end

        return sys.now() - started > duration
    end
    local function unload()
        obj:dispose()
    end
    return {
        start = start;
        draw = draw;
        unload = unload;
    }
end

local function Video(asset_name)
    print("started new video " .. asset_name)
    local file = resource.open_file(asset_name)
    local obj

    local function start()
    end
    local function draw()
        black:draw(0, 0, WIDTH, HEIGHT)

        if not obj then
            obj = resource.load_video{
                file = file;
                raw = true;
            }
        end

        local state, vw, vh = obj:state()
        if state == "finished" then
            obj:dispose()
            obj = nil
        elseif state == "loaded" then
            draw_hugged_poster(vw, vh, function(x1, y1, x2, y2)
                obj:place(x1, y1, x2, y2)
            end)
        end

        if screen.show then
            draw_show_info()
        end

        return false
    end

    local function unload()
        if obj then
            obj:dispose()
        end
    end
    return {
        start = start;
        draw = draw;
        unload = unload;
    }
end

-- Auditorium 9 seat coordinates. The guest view intentionally omits the
-- internal guide rails and wall: only seats and the animated route are shown.
local seat_rows = {
    I = {{1, 7, 46}, {9, 12, 465}},
    H = {{1, 7, 46}, {8, 15, 418}},
    G = {{1, 7, 46}, {8, 15, 418}},
    F = {{3, 7, 140}, {8, 15, 418}},
    E = {{3, 7, 140}, {8, 15, 418}},
    D = {{1, 7, 46}, {8, 11, 418}},
    C = {{1, 3, 46}, {4, 6, 232}, {7, 10, 418}},
    B = {{1, 9, 186}},
    A = {{1, 10, 93}},
}
local row_y = {I=185, H=245, G=305, F=365, E=425, D=486, C=548, B=669, A=729}
local aisle_y = {I=150, H=215, G=275, F=335, E=395, D=455, C=515, B=635, A=700}

local function seat_xy(label)
    local row, number = string.match(string.upper(label or ''), '^([A-I])(%d+)$')
    number = tonumber(number)
    if not row or not number or not seat_rows[row] then
        return nil
    end
    for _, group in ipairs(seat_rows[row]) do
        if number >= group[1] and number <= group[2] then
            return group[3] + (number - group[1]) * 47, row_y[row], row, number
        end
    end
    return nil
end

local function map_transform(x, y)
    local header = HEIGHT * 0.16
    local map_scale = math.min((WIDTH - 50) / 792, (HEIGHT - header - 25) / 760)
    local ox = (WIDTH - 792 * map_scale) / 2
    local oy = header + (HEIGHT - header - 760 * map_scale) / 2
    return ox + x * map_scale, oy + y * map_scale, map_scale
end

local function draw_segment(x1, y1, x2, y2, amount)
    if amount <= 0 then return end
    amount = math.min(1, amount)
    x2 = x1 + (x2 - x1) * amount
    y2 = y1 + (y2 - y1) * amount
    local ax, ay, s = map_transform(x1, y1)
    local bx, by = map_transform(x2, y2)
    local half = math.max(3, 5 * s)
    route_blue:draw(math.min(ax, bx)-half, math.min(ay, by)-half,
                    math.max(ax, bx)+half, math.max(ay, by)+half)
end

local function draw_path_to(label, progress)
    local sx, _, row = seat_xy(label)
    if not sx then return end
    local segments
    if row == 'A' then
        segments = {{45,748,45,620}, {45,620,120,620}, {120,620,120,700}, {120,700,sx,700}}
    elseif row == 'B' then
        segments = {{45,748,45,620}, {45,620,120,620}, {120,620,120,635}, {120,635,sx,635}}
    else
        segments = {{45,748,45,620}, {45,620,374,620}, {374,620,374,aisle_y[row]}, {374,aisle_y[row],sx,aisle_y[row]}}
    end
    local per = 1 / #segments
    for idx, segment in ipairs(segments) do
        local amount = (progress - (idx-1)*per) / per
        draw_segment(segment[1], segment[2], segment[3], segment[4], amount)
    end
end

local function draw_seat(label, x, y, selected)
    local px, py, s = map_transform(x, y)
    local w, h = 38*s, 32*s
    if selected then
        seat_blue:draw(px-w/2-4*s, py-h/2-4*s, px+w/2+4*s, py+h/2+4*s)
    else
        seat_blue:draw(px-w/2-2*s, py-h/2-2*s, px+w/2+2*s, py+h/2+2*s)
    end
    seat_fill:draw(px-w/2, py-h/2, px+w/2, py+h/2)
    local size = math.max(12, 17*s)
    local tw = font:width(label, size)
    font:write(px-tw/2, py-size/2, label, size, 1,1,1,1)
end

local function draw_seat_map()
    local selected = {}
    for _, label in ipairs(seat_navigation.seats or {}) do
        selected[string.upper(label)] = true
    end

    for row, groups in pairs(seat_rows) do
        for _, group in ipairs(groups) do
            for number = group[1], group[2] do
                local label = row .. tostring(number)
                local x, y = seat_xy(label)
                draw_seat(label, x, y, selected[label])
            end
        end
    end

    local progress = math.min(1, (sys.now() - seat_navigation_started) / 2.5)
    for _, label in ipairs(seat_navigation.seats or {}) do
        draw_path_to(label, progress)
    end

    local ex, ey = map_transform(45, 748)
    font:write(ex + 12, ey - 18, 'ENTRY', math.max(16, HEIGHT*0.023), 1,1,1,1)
end

local function draw_navigation()
    black:draw(0, 0, WIDTH, HEIGHT)
    local state = seat_navigation.state or 'error'
    local title = seat_navigation.title or ''
    local seats = table.concat(seat_navigation.seats or {}, ', ')
    local top = math.max(18, HEIGHT * 0.025)

    if state ~= 'ok' then
        warning_red:draw(0, 0, WIDTH, HEIGHT * 0.19)
    end
    draw_centered_text(title ~= '' and title or (seat_navigation.message or 'Ticket scan'), top,
                       math.max(26, HEIGHT*0.055), WIDTH-40)
    if seats ~= '' then
        draw_centered_text('Seats ' .. seats .. '  •  Auditorium ' .. tostring(seat_navigation.auditorium or ''),
                           top + HEIGHT*0.065, math.max(20, HEIGHT*0.037), WIDTH-40)
    end
    if state ~= 'ok' then
        draw_centered_text(seat_navigation.message or '', top + HEIGHT*0.065,
                           math.max(20, HEIGHT*0.035), WIDTH-40)
        draw_centered_text(seat_navigation.help or 'Please see a manager for help', top + HEIGHT*0.115,
                           math.max(18, HEIGHT*0.03), WIDTH-40)
    end
    if seat_navigation.screen_id == indy_id and #(seat_navigation.seats or {}) > 0 then
        draw_seat_map()
    end
end

local function navigation_active()
    if not seat_navigation.active then return false end
    local duration = tonumber(seat_navigation.display_seconds) or 20
    return sys.now() - seat_navigation_started < duration
end

local function Player()
    local offset = 0
    local current = Fallback(main_logo_name, 5)
    local next
    local current_key = ""

    local function asset_key()
        if not screen.show or screen.show.poster_file == "" then
            return "fallback:" .. main_logo_name
        end
        return (screen.show.media_type or "image") .. ":" .. screen.show.poster_file
    end

    current.start()
    current_key = asset_key()

    local function draw()
        local key = asset_key()
        if key ~= current_key then
            current.unload()
            current_key = key
            next = nil
            offset = 0
            current = Fallback(main_logo_name, 5)
            current.start()
        end

        if not next then
            local assets = get_assets()
            offset = offset + 1
            if offset > #assets then
                offset = 1
            end

            local asset = assets[offset]
            next = ({
                image = Image;
                video = Video;
                fallback = Fallback;
            })[asset.media.type](asset.media.asset_name, asset.duration)
        end

        local ended = current.draw()

        if ended then
            current.unload()
            current = next
            next = nil
            current.start()
        end
    end

    return {
        draw = draw;
    }
end

local player = Player()

function node.render()
    gl.clear(0, 0, 0, 1)
    st()

    gl.translate(WIDTH/2, HEIGHT/2)
    gl.scale(scale, scale)
    gl.translate(-WIDTH/2, -HEIGHT/2)

    if navigation_active() then
        draw_navigation()
    else
        player.draw()
    end

    if not indy_id then
        font:write(WIDTH/2-120, HEIGHT/2+140, "NO SCREEN CONFIGURED", 24, 1,1,1,.1)
        font:write(WIDTH/2-60, HEIGHT/2+165, my_serial, 20, 1,1,1,.1)
        return
    elseif outdated then
        font:write(WIDTH/2-110, HEIGHT/2+140, "NO RECENT SCHEDULE", 24, 1,1,1,.1)
        font:write(WIDTH/2-60, HEIGHT/2+165, my_serial, 20, 1,1,1,.1)
        return
    end

    if debug then
        local x, y = WIDTH-250, 10
        font:write(x, y, "Serial: " .. my_serial, 12, 1,1,1,1); y=y+12
        font:write(x, y, ("Time: %s"):format(local_time), 12, 1,1,1,1); y=y+12
        if screen.show then
            font:write(x, y, "Show: "..screen.show.name, 12, 1,1,1,1); y=y+12
            font:write(x, y, "Status: "..(screen.show.status_label or ""), 12, 1,1,1,1); y=y+12
            font:write(x, y, "Media: "..(screen.show.media_type or ""), 12, 1,1,1,1); y=y+12
        end
    end
end
