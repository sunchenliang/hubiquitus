#
# * Copyright (c) Novedia Group 2012.
# *
# *    This file is part of Hubiquitus
# *
# *    Permission is hereby granted, free of charge, to any person obtaining a copy
# *    of this software and associated documentation files (the "Software"), to deal
# *    in the Software without restriction, including without limitation the rights
# *    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# *    of the Software, and to permit persons to whom the Software is furnished to do so,
# *    subject to the following conditions:
# *
# *    The above copyright notice and this permission notice shall be included in all copies
# *    or substantial portions of the Software.
# *
# *    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# *    INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# *    PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
# *    FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# *    ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
# *
# *    You should have received a copy of the MIT License along with Hubiquitus.
# *    If not, see <http://opensource.org/licenses/mit-license.php>.
#

#Node modules
{EventEmitter} = require "events"
forker = require "child_process"
#Third party modules
zmq = require "zmq"
winston = require "winston"
_ = require "underscore"
#Hactor modules
{OutboundAdapter} = require "./../adapters/hAdapters"
adapters = require "./../adapters/hAdapters"
validator = require "./../validator"
codes = require "./../codes.coffee"
hFilter = require "./../hFilter"


_.mixin toDict: (arr, key) ->
  throw new Error('_.toDict takes an Array') unless _.isArray arr
  _.reduce arr, ((dict, obj) ->
    dict[ obj[key] ] = obj if obj[key]?
    return dict), {}

###*
  Class that defines an Actor
###
class Actor extends EventEmitter

  # Possible running states of an actor
  STATUS_STARTING = "starting"
  STATUS_STARTED = "started"
  STATUS_STOPPING = "stopping"
  STATUS_STOPPED = "stopped"

  # Native Actors provided by hubiquitus. If forked they will be used
  H_ACTORS = {
    hauth: true,
    hchannel: true,
    hdispatcher: true,
    hgateway: true,
    hsession: true,
    htracker: true,
    hactor: true
  }

  ###*
    Actor's constructor
    @topology {object} Launch topology of the actor
  ###
  constructor: (topology) ->
    # init logger
    if topology.log
      @log_properties = topology.log
      @initLogger(topology.log.logLevel or "info", topology.log.logFile)
    else
      @initLogger("info")

    # setting up instance attributes
    if(validator.validateFullURN(topology.actor))
      @actor = topology.actor
    else if(validator.validateURN(topology.actor))
      @actor = "#{topology.actor}/#{UUID.generate()}"
    else
      throw new Error "Invalid actor URN"
    @ressource = @actor.replace(/^.*\//, "")
    @type = "actor"
    @filter = {}
    if topology.filter
      @setFilter topology.filter, (status, result) =>
        unless status is codes.hResultStatus.OK
          # TODO arreter l'acteur
          @log "debug", "Invalid filter stopping actor"

    # Initializing class variables
    @msgToBeAnswered = {}
    @timerOutAdapter = {}
    @timerTouch = undefined
    @parent = undefined
    @touchDelay = 60000

    # Initializing attributs
    @properties = topology.properties or {}
    @status = STATUS_STOPPED
    @children = []
    @trackers = []
    @inboundAdapters = []
    @outboundAdapters = []
    @subscriptions = []

    # Registering trackers
    if _.isArray(topology.trackers) and topology.trackers.length > 0
      _.forEach topology.trackers, (trackerProps) =>
        @log "debug", "registering tracker #{trackerProps.trackerId}"
        @trackers.push trackerProps
        @outboundAdapters.push adapters.adapter("socket_out", {owner: @, targetActorAid: trackerProps.trackerId, url: trackerProps.trackerUrl})
    else
      @log "debug", "no tracker was provided"

    # registering callbacks on events
    @on "message", (hMessage) =>
      #complete msgid
      hMessage.msgid = hMessage.msgid + "#" + @makeMsgId()
      ref = undefined
      if hMessage and hMessage.ref and typeof hMessage.ref is "string"
        ref = hMessage.ref.split("#")[0]
      if ref
        cb = @msgToBeAnswered[ref]
      if cb
        delete @msgToBeAnswered[ref]
        cb hMessage
      else
        @h_onMessageInternal hMessage, (hMessageResult) =>
          @send hMessageResult

    # Setting adapters
    _.forEach topology.adapters, (adapterProps) =>
      adapterProps.owner = @
      if adapterProps.type is 'channel_in'
        attempt = 1
        @subscribe adapterProps.channel, adapterProps.quickFilter, (status, result) =>
          unless status is codes.hResultStatus.OK
            @log "debug", "Subscription attempt #{attempt} failed cause #{result} "
            SubTimer = setInterval(=>
              if attempt < 4
                @subscribe adapterProps.channel, adapterProps.quickFilter, (status2) =>
                  if status2 is codes.hResultStatus.OK
                    clearInterval(SubTimer)
                  else
                    attempt++
                    @log "debug", "Subscription attempt #{attempt} failed cause #{result} "
              else
                @log "debug", "Subscription attempt #{++attempt} failed cause #{result}, don't try again "
                clearInterval(SubTimer)
            , 5000)
      else
        adapter = adapters.adapter(adapterProps.type, adapterProps)
        if adapter.direction is "in"
          @inboundAdapters.push adapter
        else if adapter.direction is "out"
          @outboundAdapters.push adapter

    # Adding children once started
    @on "started", ->
      @initChildren(topology.children)

  ###*
    Private method called when the actor receive a hMessage.
    Check hMessage format, catch hSignal, Apply filter then calle onMessage
    @hMessage {object} the hMessage receive
    @cb {callback} callback which send an eventual result
  ###
  h_onMessageInternal: (hMessage, cb) ->
    @log "debug", "onMessage :"+JSON.stringify(hMessage)
    try
      validator.validateHMessage hMessage, (err, result) =>
        if err
          @log "debug", "hMessage not conform : "+JSON.stringify(result)
          hMessageResult = @buildResult(hMessage.publisher, hMessage.msgid, codes.hResultStatus.MISSING_ATTR, "actor is missing")
          cb hMessageResult
        else
          #Complete missing values
          hMessage.convid = (if not hMessage.convid or hMessage.convid is hMessage.msgid then hMessage.msgid else hMessage.convid)
          hMessage.published = hMessage.published or new Date().getTime()

          #Empty location and headers should not be sent/saved.
          validator.cleanEmptyAttrs hMessage, ["headers", "location"]

          if hMessage.type is "hSignal" and validator.getBareURN(hMessage.actor) is validator.getBareURN(@actor)
            switch hMessage.payload.name
              when "start"
                @h_init()
              when "stop"
                @h_tearDown()
              else
                @h_onSignal(hMessage)
          else
            #Check if hMessage respect filter
            checkValidity = @validateFilter(hMessage)
            if checkValidity.result is true
              @onMessage hMessage, cb
            else
              hMessageResult = @buildResult(hMessage.publisher, hMessage.msgid, codes.hResultStatus.INVALID_ATTR, checkValidity.error)
              cb hMessageResult

    catch error
      @log "warn", "An error occured while processing incoming message: "+error

  ###*
    Method that processes the incoming message.
    This method could be override to specified an actor
    @hMessage {object} the hMessage receive
    @cb {callback} callback which send an eventual result
  ###
  onMessage: (hMessage, cb) ->
    @log "info", "Message reveived: #{JSON.stringify(hMessage)}"
    if hMessage.timeout > 0
        hMessageResult = @buildResult(hMessage.publisher, hMessage.msgid, codes.hResultStatus.NOT_AVAILABLE, "This actor doesn't answer")
        cb hMessageResult

  ###*
    Private method that processes hSignal message.
    The hSignal are service's message
    @hMessage {object} the hSignal receive
  ###
  h_onSignal: (hMessage) ->
    @log "debug", "Actor received a hSignal: #{JSON.stringify(hMessage)}"
    if hMessage.payload.name is "hStopAlert"
      @removePeer(hMessage.payload.params)

  ###*
    Method called for sending hMessage
    Check for an outboundAdapter, then ask to the tracker if needed
    This method could be override to specified an actor
    @hMessage {object} the hMessage to send
    @cb {callback} callback to call when a answer is receive
  ###
  send: (hMessage, cb) ->
    unless _.isString(hMessage.actor)
      if cb
        cb @buildResult(hMessage.publisher, hMessage.msgid, codes.hResultStatus.MISSING_ATTR, "actor is missing")
        return
      else
        throw new Error "'aid' parameter must be a string"

    # first looking up for a cached adapter
    outboundAdapter = _.toDict( @outboundAdapters , "targetActorAid" )[hMessage.actor]
    unless outboundAdapter
      _.forEach @outboundAdapters, (outbound) =>
        if validator.getBareURN(outbound.targetActorAid) is hMessage.actor
          hMessage.actor = outbound.targetActorAid
          outboundAdapter = outbound
    if outboundAdapter
      if @timerOutAdapter[outboundAdapter.targetActorAid]
        clearTimeout(@timerOutAdapter[outboundAdapter.targetActorAid])
        @timerOutAdapter[outboundAdapter.targetActorAid] = setTimeout(=>
          delete @timerOutAdapter[outboundAdapter.targetActorAid]
          @unsubscribe @trackers[0].trackerChannel, outboundAdapter.targetActorAid, () ->
          @removePeer(outboundAdapter.targetActorAid)
        , 90000)
      @h_sending(hMessage, cb, outboundAdapter)
    # if don't have cached adapter, send lookup demand to the tracker
    else
      if @trackers[0]
        msg = @buildSignal(@trackers[0].trackerId, "peer-search", {actor:hMessage.actor}, {timeout:5000})
        @send msg, (hResult) =>
          if hResult.payload.status is codes.hResultStatus.OK
            # Subscribe to trackChannel to be alerting when actor disconnect
            found = false
            _.forEach @outboundAdapters, (outbound) =>
              if outbound.targetActorAid is hResult.payload.result.targetActorAid
                found = true
                hMessage.actor = outbound.targetActorAid
                outboundAdapter = outbound
            unless found
              outboundAdapter = adapters.adapter(hResult.payload.result.type, { targetActorAid: hResult.payload.result.targetActorAid, owner: @, url: hResult.payload.result.url })
              @outboundAdapters.push outboundAdapter
              if @actor isnt @trackers[0].trackerChannel and hResult.payload.result.targetActorAid isnt @trackers[0].trackerChannel
                @subscribe @trackers[0].trackerChannel, hResult.payload.result.targetActorAid, () ->

            @timerOutAdapter[outboundAdapter.targetActorAid] = setTimeout(=>
              delete @timerOutAdapter[outboundAdapter.targetActorAid]
              @unsubscribe @trackers[0].trackerChannel, outboundAdapter.targetActorAid, () ->
              @removePeer(outboundAdapter.targetActorAid)
            , 90000)

            hMessage.actor = hResult.payload.result.targetActorAid
            @h_sending hMessage, cb, outboundAdapter
          else
            @log "debug", "Can't send hMessage : "+hResult.payload.result
      else
        if cb
          cb @buildResult(hMessage.publisher, hMessage.msgid, codes.hResultStatus.NOT_AVAILABLE, "Can't find actor")
          return
        else
          throw new Error "Don't have any tracker for peer-searching"

  ###*
    Private method called for sending hMessage
    Complete hMessage by override some attribut, then send the hMessage from outboundAdapter
    @hMessage {object} the hMessage to send
    @cb {callback} callback to call when a answer is receive
    @outboundAdapter {object} adapter used to send hMessage
  ###
  h_sending: (hMessage, cb, outboundAdapter) ->
    @h_fillAttribut(hMessage, cb)

    errorCode = undefined
    errorMsg = undefined

    #Verify if well formatted
    unless hMessage.actor
      errorCode = codes.hResultStatus.MISSING_ATTR
      errorMsg = "the actor attribute is missing"

    unless errorCode
      #if there is a callback and no timeout, timeout is set to default value of 30s
      #Add it to the open message to call cb later
      if cb
        if hMessage.timeout > 0
          @msgToBeAnswered[hMessage.msgid] = cb
          timeout = hMessage.timeout
          self = this

          #if no response in time we call a timeout
          setTimeout (->
            if self.msgToBeAnswered[hMessage.msgid]
              delete self.msgToBeAnswered[hMessage.msgid]
              errCode = codes.hResultStatus.EXEC_TIMEOUT
              errMsg = "No response was received within the " + timeout + " timeout"
              resultMsg = self.buildResult(hMessage.publisher, hMessage.msgid, errCode, errMsg)
              cb resultMsg
          ), timeout
        else
          hMessage.timeout = 0

      #Send it to transport
      @log "debug", "Sending message: #{JSON.stringify(hMessage)}"
      outboundAdapter.send hMessage
    else if cb
      actor = hMessage.actor or "Unknown"
      resultMsg = @buildResult(actor, hMessage.msgid, errorCode, errorMsg)
      cb resultMsg

  ###*
  Private method called override some hMessage's attributs before sending
  @hMessage {object} the hMessage update
  @cb {callback} callback to define which attribut must be override
  ###
  h_fillAttribut: (hMessage, cb) ->
    #Complete hMessage
    hMessage.publisher = @actor
    if cb
      hMessage.msgid = @makeMsgId()
    else
      hMessage.msgid = hMessage.msgid or @makeMsgId()
    hMessage.sent = new Date().getTime()

  ###*
    Method allowing that creates and start an actor as a child of this actor
    @classname {string} the
    @method {string} the method to use
    @properties {object} the properties of the child actor to create
  ###
  createChild: (classname, method, properties, cb) ->

    unless _.isString(classname) then throw new Error "'classname' parameter must be a string"
    unless _.isString(method) then throw new Error "'method' parameter must be a string"

    unless properties.trackers then properties.trackers = @trackers
    unless properties.log then properties.log = @log_properties

    # prefixing actor's id automatically
    unless classname is "hchannel"
      properties.actor = "#{properties.actor}/#{UUID.generate()}"

    if H_ACTORS[classname]
      classname = "#{__dirname}/#{classname}"

    switch method
      when "inproc"
        actorModule = require "#{classname}"
        childRef = actorModule.newActor(properties)
        @outboundAdapters.push adapters.adapter(method, owner: @, targetActorAid: properties.actor , ref: childRef)
        childRef.outboundAdapters.push adapters.adapter(method, owner: childRef, targetActorAid: @actor , ref: @)
        childRef.parent = @
        # Starting the child
        @send @buildSignal(properties.actor, "start", {})

      when "fork"
        childRef = forker.fork __dirname+"/childlauncher", [classname , JSON.stringify(properties)]
        @outboundAdapters.push adapters.adapter(method, owner: @, targetActorAid: properties.actor , ref: childRef)
        childRef.on "message", (msg) =>
          if msg.state is 'ready'
            @send @buildSignal(properties.actor, "start", {})
      else
        throw new Error "Invalid method"

    if cb
      cb childRef
    # adding aid to referenced children
    @children.push properties.actor

    properties.actor

  ###*
    Method called by constructor to initializing logger
  ###
  initLogger: (logLevel, logFile) ->
    logLevels =
      debug: 0,
      info: 1,
      warn: 2,
      error:3
    @logger = new winston.Logger({levels: logLevels})
    # Don't crash on uncaught exception
    @logger.exitOnError = false

    # Set log display
    @logger.add(winston.transports.Console, {handleExceptions: true, level: logLevel})
    if logFile
      try
        @logger.add(winston.transports.File, {handleExceptions: true, filename: logFile, level: logLevel})
      catch err

  ###*
    Method that enrich a message with actor details and logs it to the console
    @message {object} the message to log
  ###
  log: (type, message) ->
    switch type
      when "debug"
        @logger.debug "#{validator.getBareURN(@actor)} | #{message}"
        break
      when "info"
        @logger.info "#{validator.getBareURN(@actor)} | #{message}"
        break
      when "warn"
        @logger.warn "#{validator.getBareURN(@actor)} | #{message}"
        break
      when "error"
        @logger.error "#{validator.getBareURN(@actor)} | #{message}"
        break

  ###*
    Method called by constructor to initializing actor's children
    This method could be override to specified an actor
    @children {Array of object} Actor's children and their topology
  ###
  initChildren: (children)->
    _.forEach children, (childProps) =>
      @createChild childProps.type, childProps.method, childProps

  ###*
    Method called every minuts to inform the tracker about the actor state
    This method could be override to specified an actor
  ###
  touchTrackers: ->
    _.forEach @trackers, (trackerProps) =>
      if trackerProps.trackerId isnt @actor
        @log "debug", "touching tracker #{trackerProps.trackerId}"
        inboundAdapters = []
        if @status isnt STATUS_STOPPING
          for inbound in @inboundAdapters
            inboundAdapters.push {type:inbound.type, url:inbound.url}
        @send @buildSignal(trackerProps.trackerId, "peer-info", {peerType:@type, peerId:validator.getBareURN(@actor), peerStatus:@status, peerInbox:inboundAdapters})

  ###*
    Method called when the actor status change
    @status {string} New status to apply
  ###
  setStatus: (status) ->
    # alter the state
    @status = status
    switch status
      when STATUS_STARTED
        @touchTrackers()
        @timerTouch = setInterval(=>
          @touchTrackers()
        , @touchDelay)
      when STATUS_STOPPING
        @touchTrackers()
        if @timerTouch
          clearInterval(@timerTouch)
    # advertise
    @emit status
    # Log
    @log "debug", "new status:#{status}"

  ###*
    Function that starts the actor, including its inbound adapters
  ###
  h_init: () ->
    @setStatus STATUS_STARTING
    @preStart ( =>
        @h_start ( =>
          @postStart ( =>
            @setStatus STATUS_STARTED)))

  preStart: (done) ->
    done()

  h_start: (done)->
    _.invoke @inboundAdapters, "start"
    _.invoke @outboundAdapters, "start"
    done()

  postStart: (done) ->
    done()

  ###*
    Function that stops the actor, including its children and adapters
  ###
  h_tearDown: () ->
    @setStatus STATUS_STOPPING
    @preStop ( =>
        @h_stop ( =>
          @postStop ( =>
            @setStatus STATUS_STOPPED)))

  preStop: (done) ->
    done()

  h_stop: (done) ->
    # Stop children first
    _.forEach @children, (childAid) =>
      @send @buildSignal(childAid, "stop", {})
    # Stop adapters second
    _.invoke @inboundAdapters, "stop"
    _.invoke @outboundAdapters, "stop"
    done()

  postStop: (done) ->
    @removeAllListeners()
    done()

  ###*
    Method called to set a filter on the actor
    This method could be override to specified an actor
    @hCondition {Object} The filter to set
    @cb {callback}
  ###
  setFilter: (hCondition, cb) ->
    if not hCondition or (hCondition not instanceof Object)
      return cb codes.hResultStatus.INVALID_ATTR, "invalid filter"

    checkFormat = hFilter.checkFilterFormat(hCondition)

    if checkFormat.result is true
      @filter = hCondition
      cb codes.hResultStatus.OK, ""
    else
      cb codes.hResultStatus.INVALID_ATTR, checkFormat.error

  ###*
    Method called on incoming message to check if the hMessage respect the actor's filter
    This method could be override to specified an actor
    @hMessage {Object} hMessage to check
  ###
  validateFilter: (hMessage) ->
    return hFilter.checkFilterValidity(hMessage, @filter)

  ###*
    Method called to subscribe to a channel
    If a quickFilter is specified, the method subscribe the actor just for this quickFilter
    @hChannel {string} URN of the channel to subscribe
    @quickFilter {string} quickFilter to apply on the channel
    @cb {callback}
  ###
  subscribe: (hChannel, quickFilter, cb) ->
    status = undefined
    result = undefined
    if typeof quickFilter is "function"
      cb = quickFilter
      quickFilter = ""
    if quickFilter is undefined or quickFilter is null
      quickFilter = ""

    for channel in @subscriptions
      if channel is hChannel
        _.forEach @inboundAdapters, (inbound) =>
          if inbound.channel is hChannel
            findfilter = false
            findglobalfilter = false
            for qckFilter in inbound.listQuickFilter
              if qckFilter is quickFilter
                findfilter = true
              if qckFilter is ""
                findglobalfilter = true
            if findfilter is false
              inbound.addFilter(quickFilter)
              if findglobalfilter
                inbound.removeFilter "", ()->
              status = codes.hResultStatus.OK
              result = "QuickFilter added"
              return
        if status isnt undefined
          return cb status, result
        else
          return cb codes.hResultStatus.NOT_AUTHORIZED, "already subscribed to channel " + hChannel

    @send @buildCommand(hChannel, "hSubscribe", {}, {timeout:3000}), (hResult) =>
      if hResult.payload.status is codes.hResultStatus.OK and hResult.payload.result
        channelInbound = adapters.adapter("channel_in", {url: hResult.payload.result, owner: @, channel: hChannel, filter: quickFilter})
        @inboundAdapters.push channelInbound
        channelInbound.start()
        @subscriptions.push hChannel
        if cb
          cb codes.hResultStatus.OK
      else
        cb hResult.payload.status, hResult.payload.result

  ###*
    Method called to unsubscribe to a channel.
    If a quickFilter is specified, the method unsubscribe the actor just for this quickFilter
    Else the actor is unsubsribe of all the channel
    @hChannel {string} URN of the channel to unsubscribe
    @quickFilter {string} quickFilter to removed from the channel
    @cb {callback}
  ###
  unsubscribe: (hChannel, quickFilter, cb) ->
    if typeof quickFilter is "function"
      cb = quickFilter
      quickFilter = undefined

    unless hChannel
      return cb codes.hResultStatus.MISSING_ATTR, "Missing channel"

    index = 0
    subs = false
    for channel in @subscriptions
      if channel is hChannel
        subs = true
        if quickFilter is undefined
          @subscriptions.splice(index, 1)
      index++

    if subs is false
      return cb codes.hResultStatus.NOT_AVAILABLE, "user not subscribed to " + hChannel
    else
      index = 0
      _.forEach @inboundAdapters, (inbound) =>
        if inbound.channel is hChannel
          if quickFilter
            inbound.removeFilter quickFilter, (result) =>
              if result
                @unsubscribe hChannel, cb
              else
                return cb codes.hResultStatus.OK, "QuickFilter removed"
          else
            inbound.stop()
            @inboundAdapters.splice(index, 1)
            return cb codes.hResultStatus.OK, "Unsubscribe from channel"
        index++

  ###*
    Method called to get the actor subscriptions
    @cb {callback}
  ###
  getSubscriptions: () ->
    return @subscriptions

  ###*
    Method called to remove a actor from outboundAdapter
    @actor {string} URN of the actor to remove
  ###
  removePeer: (actor) ->
    @log "debug", "Removing peer #{actor}"
    index = 0
    _.forEach @outboundAdapters, (outbound) =>
      if outbound.targetActorAid is actor
        outbound.stop()
        @outboundAdapters.splice(index, 1)
        if @trackers[0]
          @unsubscribe @trackers[0].trackerChannel, actor, () ->

      index++

  ###*
    BUILDERS FOR SPECIFIC MESSAGE
  ###
  buildMessage: (actor, type, payload, options) ->
    options = options or {}
    hMessage = {}
    unless actor
      throw new Error("missing actor")
    hMessage.publisher = @actor
    hMessage.msgid = UUID.generate()
    hMessage.published = hMessage.published or new Date().getTime()
    hMessage.actor = actor
    hMessage.ref = options.ref  if options.ref
    hMessage.convid = options.convid  if options.convid
    hMessage.type = type  if type
    hMessage.priority = options.priority  if options.priority
    hMessage.relevance = options.relevance  if options.relevance
    if options.relevanceOffset
      currentDate = new Date().getTime()
      hMessage.relevance = new Date(currentDate + options.relevanceOffset).getTime()
    if options.persistent isnt null or options.persistent isnt undefined
      hMessage.persistent = options.persistent
    if hMessage.persistent is null or hMessage.persistent is undefined
      hMessage.persistent = true
    hMessage.location = options.location  if options.location
    hMessage.author = options.author  if options.author
    hMessage.published = options.published  if options.published
    hMessage.headers = options.headers  if options.headers
    hMessage.payload = payload  if payload
    hMessage.timeout = options.timeout  if options.timeout
    hMessage

  buildSignal: (actor, name, params, options) ->
    params = params or {}
    options = options or {}
    options.persistent = options.persistent or false
    throw new Error("missing cmd")  unless name
    hSignal =
      name: name
      params: params

    @buildMessage actor, "hSignal", hSignal, options

  buildCommand: (actor, cmd, params, options) ->
    params = params or {}
    options = options or {}
    throw new Error("missing cmd")  unless cmd
    hCommand =
      cmd: cmd
      params: params

    @buildMessage actor, "hCommand", hCommand, options

  buildResult: (actor, ref, status, result, options) ->
    options = options or {}
    throw new Error("missing status")  if status is `undefined` or status is null
    throw new Error("missing ref")  unless ref
    hResult =
      status: status
      result: result

    options.ref = ref
    @buildMessage actor, "hResult", hResult, options

  buildMeasure: (actor, value, unit, options) ->
    unless value
      throw new Error("missing value")
    else throw new Error("missing unit")  unless unit
    @buildMessage actor, "hMeasure", {unit: unit, value: value}, options

  buildAlert: (actor, alert, options) ->
    throw new Error("missing alert")  unless alert
    @buildMessage actor, "hAlert", {alert: alert}, options

  buildAck: (actor, ref, ack, options) ->
    throw new Error("missing ack")  unless ack
    unless ref
      throw new Error("missing ref")
    else throw new Error("ack does not match \"recv\" or \"read\"")  unless /recv|read/i.test(ack)
    options = {}  if typeof options isnt "object"
    options.ref = ref
    @buildMessage actor, "hAck", {ack: ack}, options

  buildConvState: (actor, convid, status, options) ->
    unless convid
      throw new Error("missing convid")
    else throw new Error("missing status")  unless status
    options = {}  unless options
    options.convid = convid
    @buildMessage actor, "hConvState", {status: status}, options

  ###
  Create a unique message id
  ###
  makeMsgId: () ->
    msgId = UUID.generate()
    msgId


UUID = ->
UUID.generate = ->
  a = UUID._gri
  b = UUID._ha
  b(a(32), 8) + "-" + b(a(16), 4) + "-" + b(16384 | a(12), 4) + "-" + b(32768 | a(14), 4) + "-" + b(a(48), 12)

UUID._gri = (a) ->
  (if 0 > a then NaN else (if 30 >= a then 0 | Math.random() * (1 << a) else (if 53 >= a then (0 | 1073741824 * Math.random()) + 1073741824 * (0 | Math.random() * (1 << a - 30)) else NaN)))

UUID._ha = (a, b) ->
  c = a.toString(16)
  d = b - c.length
  e = "0"

  while 0 < d
    d & 1 and (c = e + c)
    d >>>= 1
    e += e
  c

exports.Actor = Actor
exports.newActor = (topology) ->
  new Actor(topology)

