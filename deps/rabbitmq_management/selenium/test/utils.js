const {By,Key,until,Builder} = require("selenium-webdriver");
require("chromedriver");

var baseUrl = process.env.RABBITMQ_URL;
var runLocal = process.env.RUN_LOCAL;
var seleniumUrl = process.env.SELENIUM_URL;
if (!process.env.RUN_LOCAL) {
  runLocal = true;
}
if (!process.env.RABBITMQ_URL) {
  baseUrl = "http://localhost:15672";
}
if (!process.env.SELENIUM_URL) {
  seleniumUrl = "http://selenium:4444/wd/hub";
}

module.exports = {
  buildDriver: (caps) => {
    builder = new Builder().forBrowser('chrome');
    if (!runLocal) {
      builder = builder.usingServer(seleniumUrl)
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
  }
};
