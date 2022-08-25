const {By,Key,until,Builder} = require("selenium-webdriver");
require("chromedriver");
var assert = require('assert');
const {buildDriver, goToHome} = require("../../utils");

var SSOHomePage = require('../../pageobjects/SSOHomePage')
var UAALoginPage = require('../../pageobjects/UAALoginPage')
var OverviewPage = require('../../pageobjects/OverviewPage')

describe("When a logged in user", function() {
  var overview
  var homePage

  before(async function() {
    driver = buildDriver();
    await goToHome(driver);
    homePage = new SSOHomePage(driver)
    uaaLogin = new UAALoginPage(driver)
    overview = new OverviewPage(driver)


  });


  it("logs out", async function() {
    await homePage.clickToLogin();
    await takeAndSaveScreenshot(driver, require('path').basename(__filename), 'beforeLogin');
    await uaaLogin.login("rabbit_admin", "rabbit_admin");
    await takeAndSaveScreenshot(driver, require('path').basename(__filename), 'afterLogin');
    await overview.isLoaded()
    await takeAndSaveScreenshot(driver, require('path').basename(__filename), 'overview');

    await overview.logout()
    await takeAndSaveScreenshot(driver, require('path').basename(__filename), 'afterLogout');
    await uaaLogin.isLoaded()
  });


  after(async function() {
   if (this.currentTest.isPassed) {
      driver.executeScript("lambda-status=passed");
    } else {    
      driver.executeScript("lambda-status=failed");
    }
    await driver.quit();
  });

})
