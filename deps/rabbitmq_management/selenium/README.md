# Automated End-to-End testing of the management ui with Selenium

We are using Selenium webdriver to simulate running the management ui in a browser.
And Mocha as the testing framework for Javascript.

To run the tests we need:
- make
- docker
- Ruby (needed to install `uaac` via `gem`)

# How tests are organized

All tests are hanging from the `test` folder. We can use subfolders to better organize them.
For instance, all OAuth2 related tests are under `test/oauth`. And under this folder
we have another subfolder, `tests/oauth/with-uaa` to group all the tests cases which run against UAA as OAuth2 server.

At the moment, there are no smart around discovering all the tests under subfolders. That will come later.
For now, the command `make run-tests` explicitly runs the test cases under `oauth/with-uaa`.

# Run existing tests against local browser

Get node.js dependencies ready:
```
npm install
```

Get UAA and RabbitMQ Ready:
```
make init-tests
```

Wait until both are running, specially UAA:
```
docker logs uaa -f
```
> once `Server startup` is visible, UAA ia ready

The available tests are:
- [test/oauth/with-uaa/landing.js](test/oauth/with-uaa/landing.js) - Test the landing page has no error message but has the SSO login button
- [test/oauth/with-uaa/happy-login.js](test/oauth/with-uaa/happy-login.js) - Test the happy login using rabbit_admin user
- [test/oauth/with-uaa/logout.js](test/oauth/with-uaa/logout.js) - Test logout
- [test/oauth/with-uaa-down/landing.js](test/oauth/with-uaa-down/landing.js) - Test the landing page has an error message

This is how to run one of those tests:
```
RUN_LOCAL=TRUE ./node_modules/.bin/mocha  --timeout 20000 test/oauth/with-uaa/happy-login.js
```

It opens up the chrome browser and you should see the interactions and once the test completes succesfully
it should print out something like :
```
  An UAA user with administrator tag
    ✔ can log in into the management ui (9812ms)


  1 passing (12s)
```  
