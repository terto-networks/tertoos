import socket
for hp in [('192.168.0.123', 8443), ('192.168.0.123', 4222)]:
    s = socket.socket()
    s.settimeout(3)
    try:
        s.connect(hp)
        print('OK', hp[0] + ':' + str(hp[1]))
    except Exception as e:
        print('FAIL', hp[0] + ':' + str(hp[1]), repr(e))
    finally:
        s.close()
