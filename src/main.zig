const c = @cImport({
    @cInclude("locale.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("alsa/asoundlib.h");
    @cInclude("sys/timerfd.h");
    @cInclude("sys/epoll.h");
});

const Mode = enum { X11, Wayland };
const mode: Mode = .X11;

const Out = switch (mode) {
    .X11 => struct {
        const x = @cImport(@cInclude("X11/Xlib.h"));

        var display: ?*x.Display = null;

        fn init() void {
            display = x.XOpenDisplay(null);
            if (display == null) @panic("XOpenDisplay");
        }

        fn deinit() void {
            x.XStoreName(display, x.DefaultRootWindow(display), null);
            if (x.XCloseDisplay(display) < 0) @panic("XCloseDisplay");
        }

        fn print() void {
            if (x.XStoreName(display, x.DefaultRootWindow(display), &status) < 0)
                @panic("XStoreName");
            _ = x.XFlush(display);
        }
    },

    .Wayland => struct {
        inline fn print() void {
            _ = c.puts(&status);
            _ = c.fflush(c.stdout);
        }
    },
};

var status: [48]u8 = undefined;
fn updateStatus() void {
    if (c.snprintf(
        &status,
        status.len,
        " B:%d V:%d%s %s ",
        fBatCapacity,
        fVolume,
        (if (fIsOn) "" else "M").ptr,
        @as([*c]u8, fDateStr.ptr),
    ) >= status.len) @panic("snprintf");
}

var bcfd: c_int = -1;
var fBatCapacity: u8 = 0;
fn readBatCapacity() void {
    var buf: [8]u8 = undefined;
    _ = c.lseek(bcfd, 0, c.SEEK_SET);
    const nread: i8 = @intCast(c.read(bcfd, &buf, 8));
    if (nread < 1) @panic("read bcfd");

    const n: usize = @intCast(nread);
    if (buf[n - 1] == '\n')
        buf[n - 1] = 0
    else
        buf[n] = 0;

    var endptr: [*c]u8 = undefined;
    const value: c_long = c.strtol(&buf, &endptr, 10);
    if (endptr == @as([*c]u8, @ptrCast(&buf))) @panic("strtol");

    fBatCapacity = @intCast(value);
}

var mixer: ?*c.snd_mixer_t = null;
var vol_min: f32 = 0;
var vol_max: f32 = 0;
var is_on: c_int = 1;
var fVolume: u8 = 0;
var fIsOn: bool = true;
fn boolFromInt(value: c_int) bool {
    return switch (value) {
        0 => false,
        else => true,
    };
}
fn on_volume_change(elem: ?*c.snd_mixer_elem_t, _: c_uint) callconv(.c) c_int {
    var vol_int: c_long = undefined;
    _ = c.snd_mixer_selem_get_playback_volume(elem, c.SND_MIXER_SCHN_FRONT_LEFT, &vol_int);
    const vol: f64 = @floatFromInt(vol_int);
    fVolume = @intFromFloat(@round(100 * (vol - vol_min) / (vol_max - vol_min)));
    _ = c.snd_mixer_selem_get_playback_switch(elem, c.SND_MIXER_SCHN_FRONT_LEFT, &is_on);
    fIsOn = boolFromInt(is_on);
    return 0;
}

var timerfd: c_int = -1;

var g_ts: c.timespec = undefined;
fn GetTime() void {
    if (c.clock_gettime(c.CLOCK_REALTIME, &g_ts) != 0)
        @panic("clock_gettime");
}

const DATE_FMT = "%a %d %b %H:%M";

var date_buf: [24]u8 = undefined;
var fDateStr: [:0]u8 = undefined;
fn updateDateStr() void {
    const tm_ptr = c.localtime(&g_ts.tv_sec);
    const n = c.strftime(&date_buf, date_buf.len, DATE_FMT, tm_ptr);
    date_buf[n] = 0;
    fDateStr = date_buf[0..n :0];
}

const BAT = "/sys/class/power_supply/BAT1/";
const MAX_EVENTS = 8;

pub fn main() u8 {
    if (comptime @hasDecl(Out, "init")) Out.init();
    defer if (comptime @hasDecl(Out, "deinit")) Out.deinit();

    const epollfd: c_int = c.epoll_create1(0);
    if (epollfd < 0) @panic("epoll_create1");
    defer _ = c.close(epollfd);

    // Date and time
    if (c.setlocale(c.LC_TIME, "") == null)
        @panic("setlocale");

    timerfd = c.timerfd_create(c.CLOCK_MONOTONIC, 0);
    if (timerfd < 0) @panic("timerfd_create");
    defer _ = c.close(timerfd);

    GetTime();

    const itval = c.itimerspec{ .it_value = .{
        .tv_sec = 60 - @rem(g_ts.tv_sec, 60) - 1,
        .tv_nsec = @as(c_long, 1e9) - g_ts.tv_nsec,
    }, .it_interval = .{
        .tv_sec = 60,
        .tv_nsec = 0,
    } };

    if (c.timerfd_settime(timerfd, 0, &itval, null) < 0)
        @panic("timerfd_settime");

    var event = c.epoll_event{
        .events = @as(u32, c.EPOLLIN) | c.EPOLLET,
        .data = .{ .u64 = @intFromEnum(EventType.TimeOut1m) },
    };
    if (c.epoll_ctl(epollfd, c.EPOLL_CTL_ADD, timerfd, &event) < 0)
        @panic("epoll_ctl");

    updateDateStr();

    // Battery capacity
    bcfd = c.open(BAT ++ "capacity", c.O_RDONLY);
    if (bcfd < 0) @panic("open BAT capacity");
    defer _ = c.close(bcfd);

    readBatCapacity();

    // ALSA
    if (c.snd_mixer_open(&mixer, 0) < 0 or
        c.snd_mixer_attach(mixer, "default") < 0 or
        c.snd_mixer_selem_register(mixer, null, null) < 0 or
        c.snd_mixer_load(mixer) < 0)
        @panic("Failed to setup ALSA mixer");
    defer _ = c.snd_mixer_close(mixer);

    var elem: ?*c.snd_mixer_elem_t = c.snd_mixer_first_elem(mixer);
    while (elem) |_| : (elem = c.snd_mixer_elem_next(elem)) {
        if (c.strcmp("Master", c.snd_mixer_selem_get_name(elem)) == 0) {
            var min: c_long = undefined;
            var max: c_long = undefined;
            _ = c.snd_mixer_selem_get_playback_volume_range(elem, &min, &max);
            vol_min = @floatFromInt(min);
            vol_max = @floatFromInt(max);

            c.snd_mixer_elem_set_callback(elem, on_volume_change);
            _ = on_volume_change(elem, 0);

            break;
        }
    } else @panic("Master channel not found");

    var alsafd: c.pollfd = undefined;
    if (c.snd_mixer_poll_descriptors(mixer, &alsafd, 1) != 1)
        @panic("snd_mixer_poll_descriptors");
    event = c.epoll_event{
        .events = @as(u32, c.EPOLLIN) | c.EPOLLET,
        .data = .{ .u64 = @intFromEnum(EventType.VolChange) },
    };
    if (c.epoll_ctl(epollfd, c.EPOLL_CTL_ADD, alsafd.fd, &event) < 0)
        @panic("epoll_ctl");

    updateStatus();
    Out.print();

    // Main epoll loop
    var events: [MAX_EVENTS]c.epoll_event = undefined;
    while (true)
        for (0..@intCast(c.epoll_wait(epollfd, &events, MAX_EVENTS, -1))) |i| {
            const ev: c.epoll_event = events[i];
            @as(EventType, @enumFromInt(ev.data.u64)).handleEvent();
            updateStatus();
            Out.print();
        };

    return 0;
}

const EventType = enum(u8) {
    TimeOut1m,
    VolChange,

    fn handleEvent(self: EventType) void {
        switch (self) {
            .TimeOut1m => {
                GetTime();
                updateDateStr();
                var buf: [8]u8 = undefined;
                _ = c.read(timerfd, &buf, 8);
                readBatCapacity();
            },

            .VolChange => _ = c.snd_mixer_handle_events(mixer),
        }
    }
};
