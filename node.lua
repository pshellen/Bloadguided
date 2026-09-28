-- Copyright (C) 2016-2019 Florian Wesch <fw@info-beamer.com>

gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

util.no_globals()

local json = require "json"
local matrix = require "matrix2d"

local font = resource.load_font "font.ttf"
local package_version = "0.1.2"
local black = resource.create_colored_texture(0, 0, 0, 1)
local badge_blue = resource.create_colored_texture(2/255, 122/255, 193/255, 1)
local badge_green = resource.create_colored_texture(0.02, 0.55, 0.18, 1)
local badge_3d = resource.load_image "3D.png"
local top_logo = resource.load_image "logo.png"
local route_blue = resource.create_colored_texture(0.02, 0.36, 0.86, 1)
local seat_chair_teal = resource.load_image "seat-chair-teal.png"
local seat_chair_yellow = resource.load_image "seat-chair-yellow.png"
local warning_red = resource.create_colored_texture(0.82, 0.16, 0.18, 1)
local screen_gray = resource.create_colored_texture(0.72, 0.74, 0.78, 1)

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
    local short = math.min(WIDTH, HEIGHT)
    layout.bottom_pad = scale_y(8)
    layout.bottom_size = short * 0.048
    layout.footer_h = math.max(short * 0.11, layout.bottom_size * 2.8)
    layout.corner_size = layout.footer_h - layout.bottom_pad * 2
    if portrait then
        layout.title_size = short * 0.08
    else
        layout.title_size = scale_s(64)
    end
    layout.badge_3d_size = short * 0.09
    layout.badge_size = scale_s(76.8)
    layout.badge_w = scale_x(572)

    local info_gap = scale_y(12)
    local poster_down = portrait and short * 0.020 or scale_y(8)
    local info_down = portrait and short * 0.170 or scale_y(40)
    local safe_inset = portrait and math.max(scale_y(100), HEIGHT * 0.10) or scale_y(32)
    local normal_footer_y = HEIGHT - safe_inset - layout.footer_h
    local lowest_footer_y = HEIGHT - scale_y(8) - layout.footer_h
    layout.footer_y = math.min(normal_footer_y + info_down, lowest_footer_y)
    layout.bottom_y = layout.footer_y + (layout.footer_h - layout.bottom_size) / 2
    layout.showtime_y = layout.footer_y - info_gap - layout.bottom_size

    local title_down = portrait and short * 0.018 or scale_y(12)
    layout.movie_y = layout.showtime_y - info_gap - layout.title_size + title_down

    layout.top_logo_y = short * 0.025
    layout.top_logo_h = short * 0.10
    layout.top_logo_w = WIDTH * 0.55
    layout.top_logo_gap = short * 0.06
    layout.poster_pad = scale_x(4)
    layout.poster_x1 = layout.poster_pad
    layout.poster_x2 = WIDTH - layout.poster_pad
    layout.badge_anchor_y = layout.top_logo_y + layout.top_logo_h + layout.top_logo_gap
    layout.poster_y = layout.badge_anchor_y + poster_down
    layout.poster_title_gap = (portrait and short * 0.050 or scale_y(36)) + title_down
    layout.poster_h = math.max(scale_y(280), layout.movie_y - layout.poster_y - layout.poster_title_gap)
    layout.poster_y2 = layout.poster_y + layout.poster_h
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

local function draw_top_logo()
    if not top_logo then return end
    local lw, lh = top_logo:size()
    local max_w, max_h = layout.top_logo_w, layout.top_logo_h
    local box_x, box_y = (WIDTH - max_w) / 2, layout.top_logo_y
    local x1, y1, x2, y2 = util.scale_into(max_w, max_h, lw, lh)
    top_logo:draw(box_x+x1, box_y+y1, box_x+x2, box_y+y2)
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
    local box_h = size + pad_y * 2
    local x1 = (WIDTH - box_w) / 2
    local y1 = (layout.badge_anchor_y or layout.poster_y) - box_h * 0.4
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

local function draw_bottom_bar()
    local screen_label = (screen.name or ""):upper()
    if screen_label == "" then return end
    local right_pad = scale_x(40)
    local size = fit_text(screen_label, layout.bottom_size, WIDTH * 0.40, 16)
    local text_w = font:width(screen_label, size)
    font:write(WIDTH-text_w-right_pad, layout.bottom_y, screen_label, size, 1,1,1,1)
end

local function draw_show_info()
    if not screen.show then return end
    local show_time = (screen.show.start or ""):upper()
    draw_badge(screen.show.status_label, screen.show.upcoming)
    draw_title_row(screen.show)
    if show_time ~= "" then
        draw_centered_text("Show Start: " .. show_time, layout.showtime_y,
                           layout.bottom_size, WIDTH-scale_x(40))
    end
    draw_bottom_bar()
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
    local x1, y1 = area_x1 + ix1, area_y1 + iy1
    local x2, y2 = area_x1 + ix2, area_y1 + iy2
    local poster_zoom = 1.08
    local center_x, center_y = (x1+x2)/2, (y1+y2)/2
    local poster_w, poster_h = (x2-x1)*poster_zoom, (y2-y1)*poster_zoom
    return center_x-poster_w/2, center_y-poster_h/2,
           center_x+poster_w/2, center_y+poster_h/2
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
        local max_w = WIDTH * 0.72
        local max_h = HEIGHT * 0.30
        local box_x = (WIDTH - max_w) / 2
        local box_y = HEIGHT * 0.27
        black:draw(0, 0, WIDTH, HEIGHT)
        local x1, y1, x2, y2 = util.scale_into(max_w, max_h, w, h)
        obj:draw(box_x + x1, box_y + y1, box_x + x2, box_y + y2)
        local screen_label = (screen.name or ""):upper()
        if screen_label ~= "" then
            local label_size = fit_text(screen_label, math.min(WIDTH,HEIGHT)*0.07, WIDTH*0.80, 18)
            local label_w = font:width(screen_label, label_size)
            font:write((WIDTH-label_w)/2, box_y+max_h+scale_y(28), screen_label,
                       label_size, 1,1,1,1)
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

local function Image(asset_name, duration)
    print("started new image " .. asset_name)
    local obj = resource.load_image(asset_name)
    local started

    local function start()
        started = sys.now()
    end
    local function draw()
        black:draw(0, 0, WIDTH, HEIGHT)
        draw_top_logo()

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
        draw_top_logo()

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
    local x1, y1 = layout.poster_x1, layout.poster_y
    local x2, y2 = layout.poster_x2, layout.poster_y2
    local area_w, area_h = x2-x1, y2-y1
    local header = area_h * 0.16
    local pad = math.max(8, math.min(area_w, area_h) * 0.015)
    local map_scale = math.min((area_w-pad*2)/792, (area_h-header-pad*2)/760)
    local ox = x1 + (area_w-792*map_scale)/2
    local oy = y1 + header + (area_h-header-760*map_scale)/2
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
    local w, h = 44*s, 39*s
    local chair = selected and seat_chair_yellow or seat_chair_teal
    chair:draw(px-w/2, py-h/2, px+w/2, py+h/2)
    local size = math.max(11, 15*s)
    local tw = font:width(label, size)
    font:write(px-tw/2, py-size*0.55, label, size, 1,1,1,1)
end

local function draw_seat_map()
    local selected = {}
    for _, label in ipairs(seat_navigation.seats or {}) do
        selected[string.upper(label)] = true
    end

    local screen_x1, screen_y1, screen_scale = map_transform(135, 55)
    local screen_x2, screen_y2 = map_transform(657, 88)
    screen_gray:draw(screen_x1, screen_y1, screen_x2, screen_y2)
    local screen_size = math.max(12, 18*screen_scale)
    local screen_text_w = font:width('SCREEN', screen_size)
    font:write((screen_x1+screen_x2-screen_text_w)/2,
               screen_y1+(screen_y2-screen_y1-screen_size)/2,
               'SCREEN', screen_size, 0.05,0.05,0.06,1)

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

end

local function draw_navigation_centered(text, y, size, max_width)
    size = fit_text(text, size, max_width, 12)
    local w = font:width(text, size)
    local center = (layout.poster_x1 + layout.poster_x2) / 2
    font:write(center-w/2, y, text, size, 1,1,1,1)
end

local function draw_navigation()
    local x1, y1 = layout.poster_x1, layout.poster_y
    local x2, y2 = layout.poster_x2, layout.poster_y2
    local area_w, area_h = x2-x1, y2-y1
    local short = math.min(area_w, area_h)
    local header_h = area_h * 0.16
    black:draw(x1, y1, x2, y2)
    local state = seat_navigation.state or 'error'
    local title = seat_navigation.title or ''
    local seats = table.concat(seat_navigation.seats or {}, ', ')
    local top = y1 + math.max(6, area_h*0.018)

    if state ~= 'ok' then
        warning_red:draw(x1, y1, x2, y1+header_h)
    end
    draw_navigation_centered(title ~= '' and title or (seat_navigation.message or 'Ticket scan'), top,
                             math.max(18, short*0.055), area_w-20)
    if seats ~= '' then
        draw_navigation_centered('Seats ' .. seats .. '  •  Auditorium ' .. tostring(seat_navigation.auditorium or ''),
                                 top+header_h*0.46, math.max(14, short*0.036), area_w-20)
    end
    if state ~= 'ok' then
        draw_navigation_centered(seat_navigation.message or '', top+header_h*0.42,
                                 math.max(13, short*0.031), area_w-20)
        draw_navigation_centered(seat_navigation.help or 'Please see a manager for help', top+header_h*0.70,
                                 math.max(12, short*0.027), area_w-20)
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

    player.draw()
    if navigation_active() then
        draw_navigation()
        if screen.show then
            draw_badge(screen.show.status_label, screen.show.upcoming)
        end
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
        font:write(x, y, "Version: " .. package_version, 12, 1,1,1,1); y=y+12
        font:write(x, y, "Serial: " .. my_serial, 12, 1,1,1,1); y=y+12
        font:write(x, y, ("Time: %s"):format(local_time), 12, 1,1,1,1); y=y+12
        if screen.show then
            font:write(x, y, "Show: "..screen.show.name, 12, 1,1,1,1); y=y+12
            font:write(x, y, "Status: "..(screen.show.status_label or ""), 12, 1,1,1,1); y=y+12
            font:write(x, y, "Media: "..(screen.show.media_type or ""), 12, 1,1,1,1); y=y+12
        end
    end
end
