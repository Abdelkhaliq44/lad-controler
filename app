# relay_server.py
import os
import asyncio
import json
from aiohttp import web, WSCloseCode

# مخزن الاتصالات: pi_id -> websocket
connected_pis = {}

# -------- WebSocket handler للـ Pi ----------
async def ws_handler(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    pi_id = None
    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.TEXT:
                try:
                    data = json.loads(msg.data)
                except json.JSONDecodeError:
                    await ws.send_str(json.dumps({"error": "invalid_json"}))
                    continue

                # تسجيل Pi
                if data.get("type") == "register":
                    pi_id = data.get("pi_id")
                    if not pi_id:
                        await ws.send_str(json.dumps({"error": "missing_pi_id"}))
                        continue
                    connected_pis[pi_id] = ws
                    print(f"[WS] Pi registered: {pi_id}")
                    await ws.send_str(json.dumps({"status": "registered"}))

                # رد/رسائل أخرى من الـ Pi (مثل status)
                else:
                    # فقط اطبع الرسائل القادمة من الـ Pi للـ server log
                    print(f"[WS] message from {pi_id}: {data}")

            elif msg.type == web.WSMsgType.ERROR:
                print('ws connection closed with exception %s' % ws.exception())

    finally:
        # عند إغلاق الاتصال، نزيل الـ Pi من القائمة إن كان مسجلاً
        if pi_id and pi_id in connected_pis and connected_pis[pi_id] is ws:
            del connected_pis[pi_id]
            print(f"[WS] Pi disconnected: {pi_id}")

    return ws

# -------- HTTP endpoint لإرسال الأوامر ----------
# مثال: GET /send?pi_id=pi_1234&command=on
async def send_command_http(request):
    pi_id = request.query.get("pi_id")
    command = request.query.get("command")
    token = request.query.get("token")  # اختياري - لو تريد تحقق بسيط

    # تحقق بسيط (يمكن تحسينه لاحقاً)
    SECRET = os.getenv("RELAY_SECRET")  # ضع SECRET في متغيرات البيئة على Render إن أردت
    if SECRET:
        if token != SECRET:
            return web.json_response({"status": "error", "reason": "invalid_token"}, status=401)

    if not pi_id or not command:
        return web.json_response({"status": "error", "reason": "missing_parameters"}, status=400)

    if pi_id not in connected_pis:
        return web.json_response({"status": "error", "reason": "pi_not_connected"}, status=404)

    pi_ws = connected_pis[pi_id]
    if pi_ws.closed:
        # تنظيف المرجع إن كان مغلقًا
        del connected_pis[pi_id]
        return web.json_response({"status": "error", "reason": "pi_not_connected"}, status=404)

    payload = {"type": "command", "command": command}
    try:
        await pi_ws.send_str(json.dumps(payload))
        return web.json_response({"status": "sent"})
    except Exception as e:
        return web.json_response({"status": "error", "reason": str(e)}, status=500)

# -------- HTTP endpoint لعرض الـ Pis المتصلة ----------
async def list_pis(request):
    pis = list(connected_pis.keys())
    return web.json_response({"connected_pis": pis})

# -------- بناء التطبيق وتشغيل السيرفر ----------
app = web.Application()
app.router.add_get("/ws", ws_handler)        # WebSocket endpoint
app.router.add_get("/send", send_command_http)  # HTTP GET to send commands
app.router.add_get("/pis", list_pis)         # list connected Pis

if __name__ == "__main__":
    port = int(os.getenv("PORT", "6789"))   # Render يستخدِم متغيّر PORT
    print(f"Starting relay server on 0.0.0.0:{port}")
    web.run_app(app, host="0.0.0.0", port=port)
