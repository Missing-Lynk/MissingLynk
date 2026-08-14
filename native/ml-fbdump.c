/* ml-fbdump - dump the scanned-out DRM planes of a running display.
 *
 * The open stack has no /dev/fb0: the video composite is scanned out on the primary plane as a
 * YUV420 dmabuf and the HUD's OSD sits on an ARGB4444 overlay plane. This reports what each
 * active plane is and streams a plane's framebuffer bytes to stdout, so a host-side tool can
 * decode and compose them into one screenshot. Vendor firmware keeps /dev/fb0 and is read that
 * way instead; this tool is the open stack's half of that pair.
 *
 * Read-only throughout: it opens the card, reads plane and framebuffer state, maps the buffers
 * for reading and copies them out. It sets no mode, touches no register and takes no master, so
 * it is safe to run while video is on the panel.
 *
 *   ml-fbdump --list           one key=value line per active plane
 *   ml-fbdump --dump <plane>   that plane's framebuffer, raw, to stdout
 *
 * The card is opened fresh rather than borrowed from ml-drmfd: reading plane state needs the
 * universal-planes client cap, which is per-open, and setting it on the shared fd would change
 * what ml-hud and ml-pipeline see. Framebuffer handles need CAP_SYS_ADMIN instead of master,
 * which root has.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* The DRM UAPI this tool uses, declared here rather than included. The native build container
 * ships no DRM headers and its distribution's archives are frozen, so an include would mean
 * either a network install in a build whose other inputs are all pinned and cached, or vendoring
 * a libdrm for eight structures. These are UAPI: the layouts and request encodings are a stable
 * kernel ABI, and the kernel's own uapi/drm headers are where they are copied from.
 */
#define DRM_IOCTL_BASE 'd'
#define DRM_IOW_(nr, type)  _IOW(DRM_IOCTL_BASE, nr, type)
#define DRM_IOWR_(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)

#define DRM_CLIENT_CAP_UNIVERSAL_PLANES 2
#define DRM_MODE_OBJECT_PLANE           0xeeeeeeee
#define DRM_PLANE_TYPE_OVERLAY          0
#define DRM_PLANE_TYPE_PRIMARY          1
#define DRM_PLANE_TYPE_CURSOR           2
#define DRM_PROP_NAME_LEN               32

struct drm_set_client_cap {
    uint64_t capability;
    uint64_t value;
};

struct drm_prime_handle {
    uint32_t handle;
    uint32_t flags;
    int32_t fd;
};

struct drm_mode_get_plane_res {
    uint64_t plane_id_ptr;
    uint32_t count_planes;
};

struct drm_mode_get_plane {
    uint32_t plane_id;
    uint32_t crtc_id;
    uint32_t fb_id;
    uint32_t possible_crtcs;
    uint32_t gamma_size;
    uint32_t count_format_types;
    uint64_t format_type_ptr;
};

struct drm_mode_fb_cmd2 {
    uint32_t fb_id;
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;
    uint32_t flags;
    uint32_t handles[4];
    uint32_t pitches[4];
    uint32_t offsets[4];
    uint64_t modifier[4];
};

struct drm_mode_map_dumb {
    uint32_t handle;
    uint32_t pad;
    uint64_t offset;
};

struct drm_mode_obj_get_properties {
    uint64_t props_ptr;
    uint64_t prop_values_ptr;
    uint32_t count_props;
    uint32_t obj_id;
    uint32_t obj_type;
};

struct drm_mode_get_property {
    uint64_t values_ptr;
    uint64_t enum_blob_ptr;
    uint32_t prop_id;
    uint32_t flags;
    char name[DRM_PROP_NAME_LEN];
    uint32_t count_values;
    uint32_t count_enum_blobs;
};

#define DRM_IOCTL_SET_CLIENT_CAP         DRM_IOW_(0x0d, struct drm_set_client_cap)
#define DRM_IOCTL_PRIME_HANDLE_TO_FD     DRM_IOWR_(0x2d, struct drm_prime_handle)
#define DRM_IOCTL_MODE_GETPROPERTY       DRM_IOWR_(0xaa, struct drm_mode_get_property)
#define DRM_IOCTL_MODE_MAP_DUMB          DRM_IOWR_(0xb3, struct drm_mode_map_dumb)
#define DRM_IOCTL_MODE_GETPLANERESOURCES DRM_IOWR_(0xb5, struct drm_mode_get_plane_res)
#define DRM_IOCTL_MODE_GETPLANE          DRM_IOWR_(0xb6, struct drm_mode_get_plane)
#define DRM_IOCTL_MODE_OBJ_GETPROPERTIES DRM_IOWR_(0xb9, struct drm_mode_obj_get_properties)
#define DRM_IOCTL_MODE_GETFB2            DRM_IOWR_(0xce, struct drm_mode_fb_cmd2)

#define MAX_PLANES 32

static int drm_open(void)
{
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    struct drm_set_client_cap cap;

    if (fd < 0) {
        fprintf(stderr, "ml-fbdump: open /dev/dri/card0: %s\n", strerror(errno));
        return -1;
    }

    /* without this only the primary plane is listed, and the OSD overlay is what makes the
     * screenshot match what the wearer sees */
    memset(&cap, 0, sizeof cap);
    cap.capability = DRM_CLIENT_CAP_UNIVERSAL_PLANES;
    cap.value = 1;
    if (ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &cap)) {
        fprintf(stderr, "ml-fbdump: universal planes unavailable: %s\n", strerror(errno));
    }

    return fd;
}

static int plane_ids(int fd, uint32_t *ids, uint32_t max)
{
    struct drm_mode_get_plane_res res;

    memset(&res, 0, sizeof res);
    if (ioctl(fd, DRM_IOCTL_MODE_GETPLANERESOURCES, &res)) {
        fprintf(stderr, "ml-fbdump: GETPLANERESOURCES: %s\n", strerror(errno));
        return -1;
    }

    if (res.count_planes > max) {
        res.count_planes = max;
    }

    res.plane_id_ptr = (uint64_t)(uintptr_t)ids;
    if (ioctl(fd, DRM_IOCTL_MODE_GETPLANERESOURCES, &res)) {
        fprintf(stderr, "ml-fbdump: GETPLANERESOURCES2: %s\n", strerror(errno));
        return -1;
    }

    return (int)res.count_planes;
}

/* The framebuffer bound to a plane, and the handle of its first buffer object. Reports 0 for a
 * plane with nothing scanned out on it (disabled overlay, unused cursor). */
static int plane_fb(int fd, uint32_t plane_id, struct drm_mode_fb_cmd2 *fb, uint32_t *crtc)
{
    struct drm_mode_get_plane plane;

    memset(&plane, 0, sizeof plane);
    plane.plane_id = plane_id;
    if (ioctl(fd, DRM_IOCTL_MODE_GETPLANE, &plane)) {
        return -1;
    }

    *crtc = plane.crtc_id;
    if (plane.fb_id == 0) {
        return 1;                       /* nothing scanned out here */
    }

    memset(fb, 0, sizeof *fb);
    fb->fb_id = plane.fb_id;
    if (ioctl(fd, DRM_IOCTL_MODE_GETFB2, fb)) {
        fprintf(stderr, "ml-fbdump: GETFB2 plane %u: %s\n", plane_id, strerror(errno));
        return -1;
    }

    return 0;
}

/* Map a framebuffer's bytes for reading. PRIME export is the path that works for the pipeline's
 * imported dmabuf and gives an exact size; a dumb buffer that refuses to export is mapped through
 * its own offset instead, which is how the HUD's overlay is allocated. */
static void *fb_map(int fd, uint32_t handle, size_t *size_out)
{
    struct drm_prime_handle prime;
    struct drm_mode_map_dumb map;
    void *px;
    off_t size;

    memset(&prime, 0, sizeof prime);
    prime.handle = handle;
    prime.flags = O_RDONLY;
    if (ioctl(fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime) == 0) {
        size = lseek(prime.fd, 0, SEEK_END);
        if (size > 0) {
            px = mmap(NULL, (size_t)size, PROT_READ, MAP_SHARED, prime.fd, 0);
            close(prime.fd);
            if (px != MAP_FAILED) {
                *size_out = (size_t)size;
                return px;
            }
        } else {
            close(prime.fd);
        }
    }

    memset(&map, 0, sizeof map);
    map.handle = handle;
    if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map)) {
        fprintf(stderr, "ml-fbdump: neither PRIME nor MAP_DUMB works for handle %u\n", handle);
        return NULL;
    }

    px = mmap(NULL, *size_out, PROT_READ, MAP_SHARED, fd, map.offset);
    if (px == MAP_FAILED) {
        fprintf(stderr, "ml-fbdump: mmap: %s\n", strerror(errno));
        return NULL;
    }

    return px;
}

/* Bytes the framebuffer occupies, from its own pitches: the last populated plane's end. Used as
 * the map size when the buffer could not be PRIME-exported (which would have reported it). */
static size_t fb_size(const struct drm_mode_fb_cmd2 *fb)
{
    size_t end = 0;

    for (int i = 0; i < 4; i++) {
        if (fb->pitches[i] == 0) {
            continue;
        }

        /* chroma planes of a 4:2:0 buffer are half height; a pitch smaller than the luma one
         * is the marker, and squaring that away here keeps the host side format-agnostic */
        uint32_t rows = fb->pitches[i] < fb->pitches[0] ? fb->height / 2 : fb->height;
        size_t plane_end = (size_t)fb->offsets[i] + (size_t)fb->pitches[i] * rows;

        if (plane_end > end) {
            end = plane_end;
        }
    }

    return end;
}

static const char *plane_kind(int fd, uint32_t plane_id);

static int do_list(int fd)
{
    uint32_t ids[MAX_PLANES];
    int n = plane_ids(fd, ids, MAX_PLANES);

    if (n < 0) {
        return 1;
    }

    for (int i = 0; i < n; i++) {
        struct drm_mode_fb_cmd2 fb;
        uint32_t crtc = 0;
        int rc = plane_fb(fd, ids[i], &fb, &crtc);

        if (rc != 0) {
            continue;                   /* unreadable or nothing scanned out */
        }

        printf("plane=%u crtc=%u kind=%s fb=%u format=%c%c%c%c width=%u height=%u size=%zu",
               ids[i], crtc, plane_kind(fd, ids[i]), fb.fb_id,
               fb.pixel_format & 0xff, (fb.pixel_format >> 8) & 0xff,
               (fb.pixel_format >> 16) & 0xff, (fb.pixel_format >> 24) & 0xff,
               fb.width, fb.height, fb_size(&fb));
        for (int p = 0; p < 4; p++) {
            if (fb.pitches[p]) {
                printf(" pitch%d=%u offset%d=%u", p, fb.pitches[p], p, fb.offsets[p]);
            }
        }

        printf("\n");
    }

    return 0;
}

/* The plane's DRM type property, as a word the host side can read. */
static const char *plane_kind(int fd, uint32_t plane_id)
{
    struct drm_mode_obj_get_properties props;
    uint32_t prop_ids[64];
    uint64_t prop_vals[64];

    memset(&props, 0, sizeof props);
    props.obj_id = plane_id;
    props.obj_type = DRM_MODE_OBJECT_PLANE;
    if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &props)) {
        return "unknown";
    }

    if (props.count_props > 64) {
        props.count_props = 64;
    }

    props.props_ptr = (uint64_t)(uintptr_t)prop_ids;
    props.prop_values_ptr = (uint64_t)(uintptr_t)prop_vals;
    if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &props)) {
        return "unknown";
    }

    for (uint32_t i = 0; i < props.count_props; i++) {
        struct drm_mode_get_property prop;

        memset(&prop, 0, sizeof prop);
        prop.prop_id = prop_ids[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &prop)) {
            continue;
        }

        if (strcmp(prop.name, "type") != 0) {
            continue;
        }

        switch (prop_vals[i]) {
        case DRM_PLANE_TYPE_OVERLAY:
            return "overlay";
        case DRM_PLANE_TYPE_PRIMARY:
            return "primary";
        case DRM_PLANE_TYPE_CURSOR:
            return "cursor";
        default:
            return "unknown";
        }
    }

    return "unknown";
}

static int do_dump(int fd, uint32_t plane_id)
{
    struct drm_mode_fb_cmd2 fb;
    uint32_t crtc = 0;
    size_t size;
    void *px;

    if (plane_fb(fd, plane_id, &fb, &crtc) != 0) {
        fprintf(stderr, "ml-fbdump: plane %u has no framebuffer\n", plane_id);
        return 1;
    }

    size = fb_size(&fb);
    px = fb_map(fd, fb.handles[0], &size);
    if (!px) {
        return 1;
    }

    if (fwrite(px, 1, size, stdout) != size) {
        fprintf(stderr, "ml-fbdump: short write\n");
        munmap(px, size);
        return 1;
    }

    fflush(stdout);
    munmap(px, size);

    return 0;
}

int main(int argc, char **argv)
{
    int fd, rc;

    if (argc < 2) {
        fprintf(stderr, "usage: %s --list | --dump <plane_id>\n", argv[0]);
        return 2;
    }

    fd = drm_open();
    if (fd < 0) {
        return 1;
    }

    if (strcmp(argv[1], "--list") == 0) {
        rc = do_list(fd);
    } else if (strcmp(argv[1], "--dump") == 0 && argc == 3) {
        rc = do_dump(fd, (uint32_t)strtoul(argv[2], NULL, 0));
    } else {
        fprintf(stderr, "usage: %s --list | --dump <plane_id>\n", argv[0]);
        rc = 2;
    }

    close(fd);

    return rc;
}
