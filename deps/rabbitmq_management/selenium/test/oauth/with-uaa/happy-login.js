const {By,Key,until,Builder} = require("selenium-webdriver");
require("chromedriver");
var assert = require('assert');
const {buildDriver, goToHome, takeAndSaveScreenshot} = require("../../utils");

var SSOHomePage = require('../../pageobjects/SSOHomePage')
var UAALoginPage = require('../../pageobjects/UAALoginPage')
var OverviewPage = require('../../pageobjects/OverviewPage')

describe("An UAA user with administrator tag", function() {
  var homePage;
  var uaaLogin;
  var overview;

  before(async function() {
    driver = buildDriver();
    await takeAndSaveScreenshot(driver, require('path').basename(__filename), 'beforeAll');
    await goToHome(driver);
    await takeAndSaveScreenshot(driver, require('path').basename(__filename), 'beforeAll2');
    homePage = new SSOHomePage(driver);
    uaaLogin = new UAALoginPage(driver);
    overview = new OverviewPage(driver);
  });

  it("can log in into the management ui", async function() {
    await takeAndSaveScreenshot(driver, require('path').basename(__filename), 'afterGoToHome');
    await homePage.clickToLogin();
    await takeAndSaveScreenshot(driver, require('path').basename(__filename), 'afterHomePageClick');
    await uaaLogin.login("rabbit_admin", "rabbit_admin");
    if (! await overview.isLoaded()) {
      throw new Error("Failed to login");
    }
    assert.equal(await overview.getUser(), "User rabbit_admin");

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
