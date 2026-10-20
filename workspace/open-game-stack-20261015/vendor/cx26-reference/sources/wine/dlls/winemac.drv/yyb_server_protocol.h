/* Generated from the immutable original server dispatch table. */
#ifndef MACDRV_YYB_SERVER_PROTOCOL_H
#define MACDRV_YYB_SERVER_PROTOCOL_H
/* Tencent inserts save_app_select_path at ordinal 7. All five direct
 * server requests here otherwise retain the public request layouts. */
C_ASSERT(REQ_set_queue_fd == 115);
#define MACDRV_YYB_REQ_set_queue_fd ((enum request)116)
C_ASSERT(REQ_set_capture_window == 195);
#define MACDRV_YYB_REQ_set_capture_window ((enum request)196)
C_ASSERT(REQ_get_window_rectangles == 156);
#define MACDRV_YYB_REQ_get_window_rectangles ((enum request)157)
C_ASSERT(REQ_set_window_pos == 155);
#define MACDRV_YYB_REQ_set_window_pos ((enum request)156)
C_ASSERT(REQ_update_window_zorder == 164);
#define MACDRV_YYB_REQ_update_window_zorder ((enum request)165)
#define MACDRV_YYB_SERVER_REQUEST(name, request) \
    ((request)->__header.req = MACDRV_YYB_REQ_##name)
#endif
