const fs = require('fs')
const fsp = fs.promises
const path = require('path');
const {By,Key,until,Builder} = require("selenium-webdriver");
require("chromedriver");

var baseUrl = process.env.RABBITMQ_URL || "http://localhost:15672";
var runLocal = String(process.env.RUN_LOCAL).toLowerCase() != "false";
var seleniumUrl = process.env.SELENIUM_URL || "http://selenium:4444";
var screenshotsDir = process.env.SCREENSHOTS_DIR || "/screens";


module.exports = {
  buildDriver: (caps) => {
    console.log("RABBITMQ_URL: " + baseUrl);

    console.log("SELENIUM_URL: " + seleniumUrl);
    builder = new Builder();
    if (!runLocal) {
      console.log("RUN_REMOTE");
      builder = builder.usingServer(seleniumUrl).forBrowser('chrome');
    } else {
      console.log("RUN_LOCAL");
      builder = builder.forBrowser('chrome');
    }
    driver = builder.build();
    driver.manage().timeouts().setScriptTimeout(10, TimeUnit.SECONDS);
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

  takeAndSaveScreenshot: async (driver, dir, name) => {
    let image = await driver.takeScreenshot();
    let screenshotsSubDir = path.join(screenshotsDir, dir);
    if (!fs.existsSync(screenshotsSubDir)) {
      await fsp.mkdir(screenshotsSubDir);
    }
    let dest = path.join(screenshotsSubDir, name + ".png");
    await fsp.writeFile(dest, image, 'base64');
  }
};
