const config = require('./config');
const fs = require('fs');
const superagent = require('superagent');
const Promise = require('bluebird');

const auth = require('../lib/auth');

/**
 * API Middleware case used to interface with the FRESCO API in the webserver
 * @description All API requests should be made through this class to have consistency and
 * have OAuth headers be automatically and correctly set
 */
const API = {

    /**
     * Express middleware, sends requests directly to the api, and sends response to the client
     * @param {Request} req Express request object
     * @param {Response} res Express response object
     * @param {Function} callback Optional callback one can override
     */
    proxy: (req, res, cb) => {
        let callback = cb;

        // Check if there is no callback, or it is from middlewhere i.e. it has `next` as the function name
        // And set a callback to send back the body
        if (!cb || cb.name === 'next') {
            // Error check callsback with body of request
            callback = (response) => (res.send(response.body));
        }

        // Send request
        API
        .request({ req, res }, req)
        .then(callback)
        .catch(error => API.handleError(error, res));
    },

    /**
     * Send a request to the api. The options object is as follows options
     *  - req     {Request} The request to base the api call off of
     *  - url     {string}  The url to call
     *  - body    {object}  The payload to send (if applicable)
     *  - method  {string}  The http verb to use
     *  - files   {object}  An associative map of files, like multer gives
     *  - token   {string}  The api authtoken to use
     *
     * Either the req field must be set, or all the other fields must be set.
     * Setting the fields manually overrides the req fields
     *
     * NOTE: When files are sent, the files are automatically deleted
     *
     * @param {object}  options  Request options
     * @param {Bool} retrying If the request is being made as a retry or not
     * @param {Object} req Express req, optionally passed if the request should attempt to retry by fetching a new bearer
     *
     * @return {Promise} resolve for 200, reject for other errors
     */
    request: (options, req = null, retrying = false) => {
        return new Promise((resolve, reject) => {
            if (options.req) {
                options.url = options.url || options.req.url;
                options.body = options.body || options.req.body;
                options.method = options.method || options.req.method;
                options.files = options.files || options.req.files;

                //Backup check if token is not passed to check session
                if(!options.token && options.req.session.user && options.req.session.token){
                    options.token = options.req.session.token.token;
                } else {
                    options.token = '';
                }

                //Check if TTL header is set
                if(options.req.headers.ttl) {
                    API.ttl(options.req);
                }
            }
            
            let request = superagent(options.method || 'GET', config.API_URL + '/' + config.API_VERSION + options.url);
            let authorization;

            //Set Authorization Header
            if(options.token === '' || typeof(options.token) == 'undefined') {
                authorization = auth.basicAuthentication(config.API_CLIENT_ID, config.API_CLIENT_SECRET);
            } else {
                authorization = auth.bearerAuthentication(options.token);
            }

            request.set('Authorization', authorization);

            // Checks to see if there are any files to upload
            if (options.method == 'POST' && Object.keys(options.files || {}).length > 0) {
                let cleanupFiles = [];

                //Attach files
                for(file of options.files) {
                    cleanupFiles.push(file.path);
                    request.attach(file.fieldname, file.path);
                }

                for (index in options.body) {
                    request.field(index, options.body[index]);
                }

                request.end((err, response) => { 
                    API
                        .end(err, response, cleanupFiles)
                        .then(resolve)
                        .catch((error) => retry(error, req, retrying));
                });
            }

            API.log(options, authorization);

            //Send reuqest normally without files
            request
            .send(options.body)
            .end((err, response) => {
                API
                    .end(err, response)
                    .then(resolve)
                    .catch((error) => retry(error, req, retrying));
            });

            //Extract so it's not duplicated
            const retry = (error, req, retrying) => {
                if(!retrying) {       
                    API
                        .retry(error, options, req)
                        .then(resolve)
                        .catch(reject)
                } else {
                    reject(error);
                }
            }
        });
    },

    /**
     * API Request `end` error handler, handles all different error edge cases
     * @param  {[type]} error    [description]
     * @param  {[type]} response [description]
     * @param {Array} cleanupFiles files to cleanup
     * @return {[type]}          [description]
     */
    end: (error, response, cleanupFiles = []) => {
        for (let index in cleanupFiles) {
            fs.unlink(cleanupFiles[index]);
        }

        if(error) {
            //Server can't connect
            if(error.code === 'ECONNREFUSED' || !error.response) {
                return Promise.reject({ msg: 'Failed to connect to Fresco!', status: 503 });
            } else {
                if(!error.response.body.error) {
                    //No error comes back from API
                    return Promise.reject({
                        msg: 'Your request could not be sent!',
                        status: error.status
                    });
                } else {
                    //Typical error
                    return Promise.reject(error.response.body.error);
                }
            }
        } else {
            //Send back regular healthy response
            return Promise.resolve(response);
        }
    },

    /**
     * Attempts to retry the request based on the error given
     * @param  {Object} error   Error from initial network reuqest
     * @param  {Object} options Request options
     * @param  {Object} req     Express request object
     * @return {Promise} resolve: healthy response, reject: errored response
     */
    retry: (error, options, req) => {
        //`401` indicates the token is invalid, hence retry should run, otherwise just reject
        if(error.status === 401) {
            //If req is not passed, we can't retry as we don't have access to the session
            if(!req) {
                return Promise.reject(error);
            }

            //Fetch new bearer
            return userLib
                .refreshBearer(req)
                .then(() => {
                    options.token = req.session.token.token; //Update token with new one from session
                    
                    //Call API request again
                    return API.request(options, req, true);
                })

        } else {
            return Promise.reject(error);
        }
    },

    /**
     * Handles API error middleware, uses `res`
     */
    handleError: (error, res) => {
        return res.status(error.status || 500).send(error);
    },

    log: (options, authorization) => {
        // Development error handle will print stacktrace
        if(config.DEV) {
            console.log(`API Request
            ---------------
            Path: ${options.url}
            Method: ${options.method},
            Body: ${JSON.stringify(options.body)}
            Authorization: ${authorization}
            ---------------`);
        }
    },

    /**
     * Resets TTL on user in session
     * @description This exists so if a client-side interaction is made that requires us to fetch
     * an updated version of the user the next time we load a page, the web-server will know
     * to do it because the TTL on the user is no longer valid
     */
    ttl: (req) => {
        req.session.user.TTL = null;
        req.session.save(null);
    }
};


module.exports = API;

//Because circular dependencies are a thing :(
const userLib = require('./user');