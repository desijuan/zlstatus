const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("alsa/asoundlib.h");
    @cInclude("sys/timerfd.h");
    @cInclude("sys/epoll.h");
});

fn print() void {
    _ = c.printf(" B:%d V:%d %s \n", fBatCapacity, fVolume, @as([*c]u8, fDateStr.ptr));
    _ = c.fflush(c.stdout);
}

var bcfd: c_int = undefined;
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
var vol_min: f64 = 0;
var vol_max: f64 = 0;
var fVolume: u8 = 0;
fn on_volume_change(elem: ?*c.snd_mixer_elem_t, _: c_uint) callconv(.c) c_int {
    var vol_int: c_long = undefined;
    _ = c.snd_mixer_selem_get_playback_volume(elem, c.SND_MIXER_SCHN_FRONT_LEFT, &vol_int);
    const vol: f64 = @floatFromInt(vol_int);
    fVolume = @intFromFloat(@round(100 * (vol - vol_min) / (vol_max - vol_min)));
    return 0;
}

var timerfd: c_int = undefined;

var g_ts: c.timespec = undefined;
fn GetTime() void {
    if (c.clock_gettime(c.CLOCK_REALTIME, &g_ts) != 0)
        @panic("clock_gettime");
}

const DATE_FMT = "%a %d %b %H:%M";

var date_buf: [32]u8 = undefined;
var fDateStr: [:0]u8 = undefined;
fn updateDateStr() void {
    const tm_ptr = c.localtime(&g_ts.tv_sec);
    const n = c.strftime(&date_buf, date_buf.len, DATE_FMT, tm_ptr);
    date_buf[n] = 0;
    fDateStr = date_buf[0..n :0];
}

inline fn printTime() void {
    _ = c.write(1, fDateStr.ptr, fDateStr.len);
}

inline fn printSecs() void {
    _ = c.printf(":%02d.%d\n", @rem(g_ts.tv_sec, 60), g_ts.tv_nsec);
}

const BAT = "/sys/class/power_supply/BAT1/";
const MAX_EVENTS = 8;

pub fn main() u8 {
    defer {
        _ = c.puts("BYE!");
        _ = c.fflush(c.stdout);
    }

    const epollfd: c_int = c.epoll_create1(0);
    if (epollfd < 0) @panic("epoll_create1");
    defer _ = c.close(epollfd);

    // Date and time
    timerfd = c.timerfd_create(c.CLOCK_MONOTONIC, 0);
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
    _ = c.epoll_ctl(epollfd, c.EPOLL_CTL_ADD, timerfd, &event);

    updateDateStr();

    // printTime();
    // printSecs();

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

    // Find Master channel
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

    // Register ALSA fds
    var pfds: [16]c.pollfd = undefined;
    const nfds: c_int = c.snd_mixer_poll_descriptors(mixer, &pfds, 16);
    for (0..@intCast(nfds)) |i| {
        event = c.epoll_event{
            .events = @as(u32, c.EPOLLIN) | c.EPOLLET,
            .data = .{ .u64 = @intFromEnum(EventType.VolChange) },
        };
        _ = c.epoll_ctl(epollfd, c.EPOLL_CTL_ADD, pfds[i].fd, &event);
    }

    print();

    // Main epoll loop
    var events: [MAX_EVENTS]c.epoll_event = undefined;
    while (true)
        for (0..@intCast(c.epoll_wait(epollfd, &events, MAX_EVENTS, -1))) |i| {
            const ev: c.epoll_event = events[i];
            @as(EventType, @enumFromInt(ev.data.u64)).handleEvent();
            print();
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
                // printTime();
                // printSecs();
                var buf: [8]u8 = undefined;
                _ = c.read(timerfd, &buf, 8);
                readBatCapacity();
            },

            .VolChange => _ = c.snd_mixer_handle_events(mixer),
        }
    }
};
