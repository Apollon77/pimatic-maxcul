module.exports = (env) ->

  {EventEmitter} = require 'events'
  HiPack = require 'hipack'
  BitSet = require 'bitset.js'
  Promise = env.require 'bluebird'
  Moment = env.require 'moment'
  Sprintf = require("sprintf-js").sprintf

  CommunicationServiceLayer = require('./communication-layer')(env)
  CulPacket = require('./culpacket')(env)

  class MaxDriver extends EventEmitter

    #Holds the the base station adress
    @baseAddress
    #Holds the instance of the communication-layer
    @comLayer

    #Supportet device types
    @deviceTypes = [
      "Cube",
      "HeatingThermostat",
      "HeatingThermostatPlus",
      "WallMountedThermostat",
      "ShutterContact",
      "PushButton"
    ]
    @_waitingForReplyQueue = []
    @msgCount
    @pairModeEnabled

    constructor: (baseAddress, pairModeEnabled, serialPortName, baudrate) ->
      @baseAddress = baseAddress
      @msgCount = 0
      @pairModeEnabled = pairModeEnabled

      @comLayer = new CommunicationServiceLayer(baudrate, serialPortName, @baseAddress)
      @comLayer.on("culDataReceived", (data) =>
        @handleIncommingMessage(data)
      )

      @comLayer.on('culFirmwareVersion', (data) =>
        env.logger.info "CUL FW Version: #{data}"
      )

      setInterval( =>
        @.emit('checkTimeIntervalFired')
      , 1000 * 60 * 60
      )

    connect: () ->
      return @comLayer.connect()

    disconnect: ->
      return @comLayer.disconnect()

    decodeCmdId: (id) ->
      key = "cmd"+id
      @commandList =
        cmd00 : {
          functionName : "PairPing"
          id : "00"
        }
        cmd01 : {
          functionName : "PairPong"
          id : "01"
        }
        cmd02 : {
          functionName : "Ack"
          id : "02"
        }
        cmd03 : {
          functionName : "TimeInformation"
          id : "03"
        }
        cmd10 : "ConfigWeekProfile"
        cmd11 : "ConfigTemperatures"
        cmd12 : "ConfigValve" #use for boost duration
        cmd20 : "AddLinkPartner"
        cmd21 : "RemoveLinkPartner"
        cmd22 : "SetGroupId"
        cmd23 : "RemoveGroupId"
        cmd30 : {
          functionName : "ShutterContactState"
          id : "30"
        }
        cmd40 : "SetTemperature"
        cmd42 : "WallThermostatControl"
        cmd43 : "SetComfortTemperature"
        cmd44 : "SetEcoTemperature"
        cmd50 : "PushButtonState"
        cmd60 : {
          functionName : "ThermostatState"
          id : 60
        }
        cmd70 : "WallThermostatState"
        cmd82 : "SetDisplayActualTemperature"
        cmdF1 : "WakeUp"
        cmdF0 : "Reset"
      return if key of @commandList then @commandList[key]['functionName'] else false

    handleIncommingMessage: (message) ->
      packet = @parseIncommingMessage(message)
      if (packet)
        if (packet.getSource() == @baseAddress)
          env.logger.debug "ignored auto-ack packet"
        else
          if ( packet.getCommand() )
            @[packet.getCommand()](packet)
          else
            env.logger.debug "received unknown command id #{packet.getRawType()}"
      else
        env.logger.debug "message was no valid MAX! paket."

    parseIncommingMessage: (message) ->
      env.logger.debug "decoding Message #{message}"
      message = message.replace(/\n/, '')
      message = message.replace(/\r/, '')
      data = message.split(/Z(..)(..)(..)(..)(......)(......)(..)(.*)/)
      data.shift() # Removes first element from array, it is the 'Z'.

      if ( data.length <= 1)
        env.logger.debug "cannot split packet"
        return false

      packet = new CulPacket()
      # Decode packet length
      packet.setLength(parseInt(data[0],16)) #convert hex to decimal

      # Check Message length
      # We get a HEX Message from the CUL, so we have 2 Digits per Byte
      # -> lengthfield from the packet * 2
      # We also have a trailing 'Z' -> + 1
      # Because the length we get from the cul is calculated for the whole packet
      # and the length field is also hex we have to add two more digits for the calculation -> +2
      if (2 * packet.getLength() + 3 != message.length)
        env.logger.debug "packet length missmatch"
        return false

      packet.setMessageCount(parseInt(data[1],16))
      packet.setFlag(parseInt(data[2],16))
      packet.setGroupId(parseInt(data[6],16))
      packet.setRawType(data[3])
      packet.setSource(data[4])
      packet.setDest(data[5])
      packet.setRawPayload(data[7])

      if @baseAddress == packet.getDest()
        packet.setForMe(true)
      else
        packet.setForMe(false)

      packet.setCommand(@decodeCmdId(data[3]))
      packet.setStatus('incomming')
      return packet

    sendMsg: (cmdId, src, dest, payload, groupId, flags, deviceType) =>
      packet = new CulPacket()
      packet.setCommand(cmdId)
      packet.setSource(src)
      packet.setDest(dest)
      packet.setRawPayload(payload)
      packet.setGroupId(groupId)
      packet.setFlag(flags)
      packet.setMessageCount(@msgCount + 1)
      packet.setRawType(deviceType)

      temp = HiPack.unpack("H*",HiPack.pack("C",packet.msgCount))
      data = temp[1]+flags+cmdId+src+dest+groupId+payload
      length = data.length/2
      length = HiPack.unpack("H*",HiPack.pack("C",length))

      packet.setRawPacket(length[1]+data)

      @comLayer.addPacketToTransportQueue(packet)

    generateTimePayload: () ->
      now = Moment()
      prep =
        sec   : now.seconds()
        min   : now.minutes()
        hour  : now.hours()
        day   : now.date()
        month : now.month() + 1
        year  : now.diff('2000-01-01', 'years'); #Years since 2000

      prep.compressedOne = prep.min | ((prep.month & 0x0C) << 4)
      prep.compressedTwo = prep.sec | ((prep.month & 0x03) << 6)

      payload = HiPack.unpack("H*",
        HiPack.pack("CCCCC",prep.year,prep.day,prep.hour,prep.compressedOne,prep.compressedTwo)
      )
      return payload[1];

    sendTimeInformation: (dest, deviceType) ->
      payload = @generateTimePayload()
      @sendMsg("03",@baseAddress,dest,payload,"00","04",deviceType);

    sendConfig: (dest,comfortTemperature,ecoTemperature,minimumTemperature,maximumTemperature,offset,windowOpenTime,windowOpenTemperature,deviceType) ->
      comfortTemperatureValue = Sprintf('%02x',(comfortTemperature*2))
      ecoTemperatureValue = Sprintf('%02x',(ecoTemperature*2))
      minimumTemperatureValue = Sprintf('%02x',(minimumTemperature*2))
      maximumTemperaturenValue = Sprintf('%02x',(maximumTemperature*2))
      offsetValue = Sprintf('%02x',((offset + 3.5)*2))
      windowOpenTempValue = Sprintf('%02x',(windowOpenTemperature*2))
      windowOpenTimeValue = Sprintf('%02x',(Math.ceil(windowOpenTime/5)))

      payload = comfortTemperatureValue+ecoTemperatureValue+maximumTemperaturenValue+minimumTemperatureValue+offsetValue+windowOpenTempValue+windowOpenTimeValue
      @sendMsg("11",@baseAddress,dest,payload,"00","00",deviceType)
      return Promise.resolve true

    sendDesiredTemperature: (dest,temperature,mode,groupId,deviceType) ->
      modeBin = switch mode
        when 'auto'
          '00'
        when 'manu'
          '01'
        when 'boost'
          '11'
      if temperature <= 4.5
        temperature = 4.5
      if temperature >= 30.5
        temperature = 30.5

      if mode is 'auto' and (typeof temperature is "undefined" or temperature is null)
        payloadHex = "00"
      else
        # Multiply the temperature with 2 to remove eventually supplied 0.5 and convert to
        # binary
        # We can't get a value smaller than 4.5 (0FF) and
        # higher as 30.5 (ON)(see the specifications of the system)
        # example: 30.5 degrees * 2 = 61
        # example: 3 degrees * 2 = 6
        temperature = (temperature * 2).toString(2)
        # Fill the value with zeros so that we allways get 6 bites
        # example: 61 =  0011 1101 => 000000 00111101 => 111101
        # example: 6 =  0110 => 000000 0110 => 000110
        temperatureBinary =  ("000000" + temperature).substr(-6);
        # Add the mode at the position of the removed bits
        # example: Mode temporary 11 => 11 111101
        # example: Mode manuel 01 => 01 000110
        payloadBinary = modeBin + temperatureBinary
        # convert the binary payload to hex
        payloadHex = parseInt(payloadBinary, 2).toString(16);

      #if a  groupid is given we set the flag to 04 to switch all devices in this group
      if groupId == "00"
        @sendMsg("40",@baseAddress,dest,payloadHex,"00","00",deviceType);
      else
        @sendMsg("40",@baseAddress,dest,payloadHex,groupId,"04",deviceType);

      return Promise.resolve true

    parseTemperature: (temperature) ->
      if temperature == 'on'
        return 30.5
      else if temperature == 'off'
        return 4.5
      else return temperature

    PairPing: (packet) ->
      env.logger.debug "handling PairPing packet"
      if(@pairModeEnabled)
        packet.setDecodedPayload(HiPack.unpack("Cfirmware/Ctype/Ctest/a*serial",HiPack.pack("H*",packet.rawPayload)))
        if (packet.getDest() != "000000" && packet.getForMe() != true)
          #Pairing Command is not for us
          env.logger.debug "handled PairPing packet is not for us"
          return
        else if ( packet.getForMe() ) #The device only wants to repair
          env.logger.debug "beginn repairing with device #{packet.getSource()}"
          @sendMsg("01", @baseAddress, packet.getSource(), "00", "00", "00", "")
        else if ( packet.getDest() == "000000" ) #The device is new and needs a full pair
          env.logger.debug "beginn pairing of a new device with deviceId #{packet.getSource()}"
          @sendMsg("01", @baseAddress, packet.getSource(), "00", "00", "00", "")
      else
          env.logger.debug ", but pairing is disabled so ignore"

    Ack: (packet) ->
      temp = HiPack.unpack("C",HiPack.pack("H*",packet.getRawPayload()))
      packet.setDecodedPayload(temp[1])
      if( packet.getDecodedPayload() == 1 )
        env.logger.debug "got OK-ACK Packet from #{packet.getSource()}"
        @comLayer.ackPacket()
      else
        #????
        env.logger.debug "got ACK Error (Invalid command/argument) from #{packet.getSource()} with payload #{packet.decodedPayload}"

    ShutterContactState: (packet) ->
      rawBitData = new BitSet('0x'+packet.getRawPayload())

      shutterContactState =
        src : packet.getSource()
        isOpen : rawBitData.get(1)
        rfError : rawBitData.get(6)
        batteryLow : rawBitData.get(7)

      env.logger.debug "got data from shutter contact #{packet.getSource()} #{rawBitData.toString()}"
      @.emit('ShutterContactStateRecieved',shutterContactState)

    ThermostatState: (packet) ->
      env.logger.debug "got data from heatingelement #{packet.getSource()} with payload #{packet.getRawPayload()}"

      rawPayload = packet.getRawPayload()

      if( rawPayload.length >= 10)
        if( rawPayload.length == 10)
          rawData = HiPack.unpack("Cbits/CvalvePosition/CdesiredTemp/CuntilOne/CuntilTwo",HiPack.pack("H*",rawPayload));
        else
          rawData = HiPack.unpack("Cbits/CvalvePosition/CdesiredTemp/CuntilOne/CuntilTwo/CuntilThree",HiPack.pack("H*",rawPayload));

        rawBitData = new BitSet(rawData.bits);
        rawMode = rawBitData.getRange(0,1);
        #If the control mode is not "temporary", the cube sends the current (measured) temperature
        if( rawData.untilTwo && rawMode[0] != 2)
          calculatedMeasuredTemperature = (((rawData.untilOne &0x01)<<8) + rawData.untilTwo)/10;
        else
          calculatedMeasuredTemperature = 0;
        #Sometimes the HeatingThermostat sends us temperatures like 0.2 or 0.3 degree Celcius - ignore them
        if ( calculatedMeasuredTemperature != 0 && calculatedMeasuredTemperature < 1)
          calculatedMeasuredTemperature = 0
        untilString = "";

        if( rawData.untilThree && rawMode[0] == 2)
          timeData = ParseDateTime(rawData.untilOne,rawData.untilTwo,rawData.untilThree)
          untilString = timeData.dateString;
        #Todo: Implement offset handling

        thermostatState =
          src : packet.getSource()
          mode : rawMode[0]
          desiredTemperature : (rawData.desiredTemp&0x7F)/2.0
          valvePosition : rawData.valvePosition
          measuredTemperature : calculatedMeasuredTemperature
          dstSetting : rawBitData.get(3)
          langateway : rawBitData.get(4)
          panel : rawBitData.get(5)
          rferror : rawBitData.get(6)
          batterylow : rawBitData.get(7)
          untilString : untilString

        @.emit('ThermostatStateRecieved',thermostatState)
      else
        env.logger.debug "payload to short ?";

    TimeInformation: (packet) ->
      env.logger.debug "got time information request from device #{packet.getSource()}"
      @.emit('deviceRequestTimeInformation',packet.getSource())

    ParseDateTime: (byteOne,byteTwo,byteThree) ->
      timeData =
        day : byteOne & 0x1F
        month : ((byteTwo & 0xE0) >> 4) | (byteThree >> 7)
        year : byteTwo & 0x3F
        time : byteThree & 0x3F
        dateString : ""

      if (timeData.time%2)
        timeData.time = parseInt(time/2)+":30";
      else
        timeData.time = parseInt(time/2)+":00";

      timeData.dateString = timeData.day+'.'+timeData.month+'.'+timeData.year+' '+timeData.time
      return timeData;
