@include = ->
    @use \json, @app.router, @express.static __dirname
    @use \/edit @express.static __dirname
    @use \/view @express.static __dirname

    @include \dotcloud
    @include \player-broadcast
    @include \player-graph
    @include \player

    DB = @include \db
    SC = @include \sc

    KEY = @KEY
    BASEPATH = @BASEPATH

    HMAC_CACHE = {}
    hmac = if !KEY then -> it else -> HMAC_CACHE[it] ||= do
        encoder = require \crypto .createHmac \sha256 KEY
        encoder.update it.toString!
        encoder.digest \hex

    [   Text,      Html,     Csv,     Json             ] = <[
        text/plain text/html text/csv application/json
    ]>.map (+ "; charset=utf-8")

    const RealBin = require \path .dirname do
        require \fs .realpathSync __filename

    sendFile = (file) -> ->
        @response.type Html
        @response.sendfile "#RealBin/#file"

    if @CORS
      console.log "Cross-Origin Resource Sharing (CORS) enabled."
      @all \* (,, next) ->
        @response.header \Access-Control-Allow-Origin  \*
        @response.header \Access-Control-Allow-Headers \X-Requested-With
        next!

    @get '/': sendFile \index.html
    @get '/favicon.ico': -> @response.send 404 ''
    @get '/_new': ->
        room = require \uuid-pure .newId 10 36 .toLowerCase!
        @response.redirect if KEY then "#BASEPATH/#room/edit" else "#BASEPATH/#room"
    @get '/_start': sendFile \start.html
    @get '/:room':
        if KEY then ->
            | @query.auth?length    => sendFile \index.html .call @
            | otherwise             => @response.redirect "#BASEPATH/#{ @params.room }?auth=0"
        else sendFile \index.html
    @get '/:room/edit': ->
        room = @params.room
        @response.redirect "#BASEPATH/#room?auth=#{ hmac room }"
    @get '/:room/view': ->
        room = @params.room
        @response.redirect "#BASEPATH/#room?auth=0"

    IO = @io
    api = (cb) -> ->
        {snapshot} <~ SC._get @params.room, IO
        if snapshot
            [type, content] = cb.call @params, snapshot
            if content instanceof Function
              rv <~ content SC[@params.room]
              @response.type type
              @response.send 200 rv
            else
              @response.type type
              @response.send 200 content
        else
            @response.type Text
            @response.send 404 ''

    @get '/_/:room/cells/:cell': api -> [Json
        (sc, cb) ~> sc.exportCell @cell, cb
    ]
    @get '/_/:room/cells': api -> [Json
        (sc, cb) -> sc.exportCells cb
    ]
    @get '/_/:room/html': api -> [Html
        (sc, cb) -> sc.exportHTML cb
    ]
    @get '/_/:room/csv': api -> [Csv
        (sc, cb) -> sc.exportCSV cb
    ]
    @get '/_/:room': api -> [Text, it]

    @put '/_/:room': ->
        buf = ''
        @request.setEncoding \utf8
        @request.on \data (chunk) ~> buf += chunk
        @request.on \end ~>
            <~ SC._put @params.room, buf
            @response.type Text
            @response.send 201 \OK

    @post '/_/:room': ->
        {room} = @params
        command = @body?command
        unless command
            @response.type Text
            return @response.send 400 'Please send command'
        command = [command] unless Array.isArray command
        <~ SC._get room, IO
        SC[room]?ExecuteCommand command * \\n
        IO.sockets.in "log-#room" .emit \data {
            type: \execute
            cmdstr: command * \\n
            room
        }
        @response.json 202 {command}

    @post '/_': ->
        room = @body?room
        snapshot = @body?snapshot
        unless room and snapshot
            @response.type Text
            return @response.send 400 'Please send room and snapshot'
        <~ SC._put room, snapshot
        @response.type Text
        @response.send 201 \OK

    @on disconnect: !->
        { id } = @socket
        :CleanRoom for key of IO.sockets.manager.roomClients[id] when key is // ^/log- //
            room = key.substr(5)
            for client in IO.sockets.clients(key.substr(1))
            | client.id isnt id => continue CleanRoom
            SC[room]?terminate!
            delete SC[room]

    @on data: !->
        {room, msg, user, ecell, cmdstr, type, auth} = @data
        room = "#room" - /^_+/ # preceding underscore is reserved
        reply = (data) ~> @emit {data}
        broadcast = (data) ~>
            @socket.broadcast.to do
                if @data.to then "user-#{@data.to}" else "log-#room"
            .emit \data data
        switch type
        | \chat
            <~ DB.rpush "chat-#room" msg
            broadcast @data
        | \ask.ecells
            _, values <~ DB.hgetall "ecell-#room"
            broadcast { type: \ecells, ecells: values, room }
        | \my.ecell
            DB.hset "ecell-#room", user, ecell
        | \execute
            return if auth is \0 or KEY and hmac(room) isnt auth
            <~ DB.multi!
                .rpush "log-#room" cmdstr
                .rpush "audit-#room" cmdstr
                .bgsave!.exec!
            SC[room]?ExecuteCommand cmdstr
            broadcast @data
        | \ask.log
            @socket.join "log-#room"
            @socket.join "user-#user"
            _, [snapshot, log, chat] <~ DB.multi!
                .get "snapshot-#room"
                .lrange "log-#room" 0 -1
                .lrange "chat-#room" 0 -1
                .exec!
            SC[room] = SC._init snapshot, log, DB, room, @io
            reply { type: \log, room, log, chat, snapshot }
        | \ask.recalc
            @socket.join "recalc.#room"
            {log, snapshot} <~ SC._get room, @io
            reply { type: \recalc, room, log, snapshot }
        | \stopHuddle
            return if @KEY and KEY isnt @KEY
            <~ DB.del <[ audit log chat ecell snapshot ]>.map -> "#it-#room"
            SC[room]?terminate!
            delete SC[room]
            broadcast @data
        | \ecell
            return if auth is \0 or KEY and auth isnt hmac room
            broadcast @data
        | otherwise
            broadcast @data
