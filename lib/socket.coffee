_             = require("lodash")
fs            = require("fs-extra")
path          = require("path")
uuid          = require("node-uuid")
Fixtures      = require("./fixtures")
Request       = require("./request")
Log           = require("./log")
Reporter      = require("./reporter")
socketIo      = require("socket.io")

leadingSlashesRe = /^\/+/

class Socket
  constructor: (server) ->
    if not (@ instanceof Socket)
      return new Socket(server)

    if not server
      throw new Error("Instantiating lib/socket requires an server instance!")

    @server      = server
    @app         = server.app
    # @reporter    = Reporter(@app)

  onTestFileChange: (filePath, stats) ->
    Log.info "onTestFileChange", filePath: filePath

    ## simple solution for preventing firing test:changed events
    ## when we are making modifications to our own files
    return if @app.enabled("editFileMode")

    ## return if we're not a js or coffee file.
    ## this will weed out directories as well
    return if not /\.(js|coffee)$/.test filePath

    fs.statAsync(filePath).bind(@)
      .then ->
        ## strip out our testFolder path from the filePath, and any leading forward slashes
        filePath      = filePath.split(@app.get("cypress").projectRoot).join("").replace(leadingSlashesRe, "")
        strippedPath  = filePath.replace(@app.get("cypress").testFolder, "").replace(leadingSlashesRe, "")

        Log.info "generate:ids:for:test", filePath: filePath, strippedPath: strippedPath
        @io.emit "generate:ids:for:test", filePath, strippedPath
      .catch(->)

  watchTestFileByPath: (testFilePath, watchers) ->
    ## normalize the testFilePath
    testFilePath = path.join(@testsDir, testFilePath)

    ## bail if we're already watching this
    ## exact file
    return if testFilePath is @testFilePath

    Log.info "watching test file", {path: testFilePath}

    ## remove the existing file by its path
    watchers.remove(testFilePath)

    ## store this location
    @testFilePath = testFilePath

    watchers.watchAsync(testFilePath, {
      onChange: @onTestFileChange.bind(@)
    })

  onRequest: (options, cb) ->
    Request.send(options)
      .then(cb)
      .catch (err) ->
        cb({__error: err.message})

  onFixture: (fixture, cb) ->
    Fixtures(@app).get(fixture)
      .then(cb)
      .catch (err) ->
        cb({__error: err.message})

  _startListening: (watchers, options) ->
    _.defaults options,
      socketId: null
      onConnect: ->
      onChromiumRun: ->
      checkForAppErrors: ->

    messages = {}
    chromiums = {}

    {projectRoot, testFolder, socketIoRoute} = @app.get("cypress")

    @io = socketId(@server, {path: socketIoRoute})

    @io.on "connection", (socket) =>
      Log.info "socket connected"

      socket.on "chromium:connected", =>
        return if socket.inChromiumRoom

        socket.inChromiumRoom = true
        socket.join("chromium")

        socket.on "chromium:history:response", (id, response) =>
          if message = chromiums[id]
            delete chromiums[id]
            message(response)

      socket.on "history:entries", (cb) =>
        id = uuid.v4()

        chromiums[id] = cb

        if _.keys(@io.sockets.adapter.rooms.chromium).length > 0
          messages[id] = cb
          @io.to("chromium").emit "chromium:history:request", id
        else
          cb({__error: "Could not process 'history:entries'. No chromium servers connected."})

      socket.on "remote:connected", =>
        Log.info "remote:connected"

        return if socket.inRemoteRoom

        socket.inRemoteRoom = true
        socket.join("remote")

        socket.on "remote:response", (id, response) =>
          if message = messages[id]
            delete messages[id]
            Log.info "remote:response", id: id, response: response
            message(response)

      socket.on "client:request", (message, data, cb) =>
        ## if cb isnt a function then we know
        ## data is really the cb, so reassign it
        ## and set data to null
        if not _.isFunction(cb)
          cb = data
          data = null

        id = uuid.v4()

        Log.info "client:request", id: id, msg: message, data: data

        if _.keys(@io.sockets.adapter.rooms.remote).length > 0
          messages[id] = cb
          @io.to("remote").emit "remote:request", id, message, data
        else
          cb({__error: "Could not process '#{message}'. No remote servers connected."})

      socket.on "run:tests:in:chromium", (src) ->
        options.onChromiumRun(src)

      socket.on "watch:test:file", (filePath) =>
        @watchTestFileByPath(filePath, watchers)

      socket.on "request", =>
        @onRequest.apply(@, arguments)

      socket.on "fixture", =>
        @onFixture.apply(@, arguments)

      socket.on "finished:generating:ids:for:test", (strippedPath) =>
        Log.info "finished:generating:ids:for:test", strippedPath: strippedPath
        @io.emit "test:changed", file: strippedPath

      _.each "load:spec:iframe url:changed page:loading command:add command:attrs:changed runner:start runner:end before:run before:add after:add suite:add suite:start suite:stop test test:add test:start test:end after:run test:results:ready exclusive:test".split(" "), (event) =>
        socket.on event, (args...) =>
          args = _.chain(args).reject(_.isUndefined).reject(_.isFunction).value()
          @io.emit event, args...

      # socket.on "app:errors", (err) ->
        # process.stdout.write "app:errors"
        # options.onAppError(err)

      socket.on "app:connect", (socketId) ->
        options.onConnect(socketId, socket)

    @testsDir = path.join(projectRoot, testFolder)

    fs.ensureDirAsync(@testsDir).bind(@)

  startListening: (watchers, options) ->
    if process.env["CYPRESS_ENV"] is "development"
      @listenToCssChanges(watchers)

    @_startListening(watchers, options)

  listenToCssChanges: (watchers) ->
    watchers.watch path.join(process.cwd(), "lib", "public", "css"), {
      ignored: (path, stats) =>
        return false if fs.statSync(path).isDirectory()

        not /\.css$/.test path
      onChange: (filePath, stats) =>
        filePath = path.basename(filePath)
        @io.emit "cypress:css:changed", file: filePath
    }

  close: ->
    @io.close()

module.exports = Socket