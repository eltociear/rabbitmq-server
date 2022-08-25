const fsp = require('fs').promises
const path = require('path');
const {By,Key,until,Builder} = require("selenium-webdriver");
require("chromedriver");

var baseUrl = process.env.RABBITMQ_URL;
var runLocal = (String(process.env.RUN_LOCAL).toLowerCase() == "true");
var seleniumUrl = process.env.SELENIUM_URL;
if (!process.env.RUN_LOCAL) {
  runLocal = true;
}
if (!process.env.RABBITMQ_URL) {
  baseUrl = "http://localhost:15672";
}
if (!process.env.SELENIUM_URL) {
  seleniumUrl = "http://selenium:4444";
}

module.exports = {
  buildDriver: (caps) => {
    console.log("RABBITMQ_URL: " + baseUrl);

    console.log("SELENIUM_URL: " + seleniumUrl);
    builder = new Builder();
    if (!runLocal) {
      console.log("RUN_REMOTE");
      builder = builder.usingServer(seleniumUrl).forBrowser('chrome');
    }else {
      console.log("RUN_LOCAL");
      builder = builder.forBrowser('chrome');
    }
    driver = builder.build();
    return driver;
  },

  goToHome: (driver) => {
    return driver.get(baseUrl)
  },

  delay: async (msec, ref) => {
    return new Promise(resolve => {
      setTimeout(resolve, msec, ref);
    })
  },

  takeAndSaveScreenshot: async (driver, name) => {
    let image = await driver.takeScreenshot();
    let dest = path.join("/screens", name + ".png");
    await fsp.writeFile(dest, image, 'base64');
  }
};
