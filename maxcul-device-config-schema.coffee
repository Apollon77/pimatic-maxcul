module.exports = {
  title: "pimatic-maxcul device config schemas"
  MaxculShutterContact:{
    title: "Config options for the Maxcul ShutterContact"
    type: "object"
    properties: {
      id:
        description: "ID of the Device"
        type: "string"
        default: ""
      deviceId:
        description: "ID of the Device in the MAX! Network"
        type: "string"
        default: "000000"
      name:
        description: "Name of the Device"
        type: "string"
        default: "000000"
      groupId:
        description : "Group/Room id of the Device"
        type: "string"
        default: "00"
    }
  },
  MaxculHeatingThermostat:{
    title: "Config options for the Maxcul HeatingThermostat"
    type: "object"
    properties: {
      id:
        description: "ID of the Device"
        type: "string"
        default: ""
      deviceId:
        description: "ID of the Device in the MAX! Network"
        type: "string"
        default: "000000"
      name:
        description: "Name of the Device"
        type: "string"
        default: "000000"
      groupId:
        description : "Group/Room id of the Device"
        type: "string"
        default: "00"
      comfyTemp:
        description: "The defined comfort mode temperature"
        type: "number"
        default: 21
      ecoTemp:
        description: "The defined eco mode temperature"
        type: "number"
        default: 17
      guiShowTemperatueInput:
        description: "Show the temperature input spinbox in the gui"
        type: "boolean"
        default: true
      guiShowModeControl:
        description: "Show the mode buttons in the gui"
        type: "boolean"
        default: true
      guiShowPresetControl:
        description: "Show the preset temperatures in the gui"
        type: "boolean"
        default: true
    }
  }
}
