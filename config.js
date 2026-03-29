module.exports = {
  serialPort: process.env.SERIAL_PORT || "",
  modbusSlaveId: parseInt(process.env.MODBUS_SLAVE_ID || "1", 10),
  modbusBaudrate: parseInt(process.env.MODBUS_BAUDRATE || "9600", 10),

  mqttHost: process.env.MQTT_HOST || "",
  mqttPort: parseInt(process.env.MQTT_PORT || "1883", 10),
  mqttUser: process.env.MQTT_USER || "",
  mqttPass: process.env.MQTT_PASS || "",
  mqttPrefix: process.env.MQTT_PREFIX || "sofar",

  timezone: process.env.ADDON_TIMEZONE || "UTC"
};
