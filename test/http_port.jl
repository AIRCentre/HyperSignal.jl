# HTTP 2 reports the bound port; HTTP 1 needs the listener's socket.
bound_port(srv) = pkgversion(HTTP) >= v"2" ? srv.bound_port :
    Sockets.getsockname(srv.listener.server)[2]
