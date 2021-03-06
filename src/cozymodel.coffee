client = require './utils/client'
Model = require './model'
util = require 'util'
simplebufferstream = require 'simple-bufferstream'
LaterStream = require './utils/later_stream'

# utility functions
checkError = (error, response, body, code, callback) ->
    callback errorMaker error, response, body, code

errorMaker = (error, response, body, expectedCode) ->
    if error
        return error
    else if response.statusCode isnt expectedCode
        msgStatus = "expected: #{expectedCode}, got: #{response.statusCode}"
        err = new Error "#{msgStatus} -- #{body.error} -- #{body.reason}"
        err.status = response.statusCode
        return err
    else
        return null

# monkeypath
FormData = require 'form-data'
_old = FormData::pipe
FormData::pipe = (request) ->
    length = request.getHeader 'Content-Length'
    request.removeHeader 'Content-Length' unless length
    _old.apply this, arguments


cozyDataAdapter =

    exists: (id, callback) ->
        client.get "data/exist/#{id}/", (error, response, body) ->
            if error
                callback error
            else if not body? or not body.exist?
                callback new Error "Data system returned invalid data."
            else
                callback null, body.exist

    find: (id, callback) ->
        client.get "data/#{id}/", (error, response, body) ->
            if error
                callback error
            else if response.statusCode is 404
                callback null, null
            else
                callback null, body

    create: (attributes, callback) ->
        path = "data/"
        if attributes.id?
            path += "#{attributes.id}/"
            delete attributes.id
            return callback new Error 'cant create an object with a set id'

        client.post path, attributes, (error, response, body) ->
            if error
                callback error
            else if response.statusCode is 409
                callback new Error "This document already exists"
            else if response.statusCode isnt 201
                callback new Error "Server error occured."
            else
                body.id = body._id
                callback null, body

    save: (id, data, callback) ->
        client.put "data/#{id}/", data, (error, response, body) ->
            if error
                callback error
            else if response.statusCode is 404
                callback new Error "Document #{id} not found"
            else if response.statusCode isnt 200
                callback new Error "Server error occured."
            else
                callback null, body

    updateAttributes: (id, data, callback) ->
        client.put "data/merge/#{id}/", data, (error, response, body) ->
            if error
                callback error
            else if response.statusCode is 404
                callback new Error "Document #{id} not found"
            else if response.statusCode isnt 200
                callback new Error "Server error occured."
            else
                callback null, body

    destroy: (id, callback) ->
        client.del "data/#{id}/", (error, response, body) ->
            if error
                callback error
            else if response.statusCode is 404
                callback new Error "Document #{id} not found"
            else if response.statusCode isnt 204
                callback new Error "Server error occured."
            else
                callback null

cozyIndexAdapter =

    search: (query, callback) ->
        docType = @getDocType()
        data = if typeof query is 'string' then query: query else query
        client.post "data/search/#{docType}", data, (error, response, body) ->
            if error
                callback error
            else if response.statusCode isnt 200
                callback new Error util.inspect body
            else
                results = body.rows
                results.totalHits = body.totalHits
                results.facets = body.facets
                results.hits = body.hits
                callback null, results

    registerIndexDefinition: (callback) ->
        docType = @getDocType()
        definitions = @fullTextIndex

        unless definitions
            setImmediate callback
        else
            url = "data/index/define/#{docType}"
            client.post url, definitions, callback

    index: (id, fields, callback) ->
        cb = (error, response, body) ->
            if error
                callback error
            else if response.statusCode isnt 200
                callback new Error util.inspect body
            else
                callback null

        client.post "data/index/#{id}", {fields}, cb, false


# FormData and thus request-json-light accept only a few things for sending
# files: strings (as a filenames) and some very specific streams (like those
# of fs.createReadableStream). Sometimes, we have buffers to send and we use
# a work-around to make them look like a stream from fs.createReadableStream.
#
# See https://github.com/form-data/form-data/pull/70
fixForBuffer = (file) ->
    if Buffer.isBuffer file
        stream = simplebufferstream file
        stream.fd = true
        stream.start = 0
        if process.version.match /^v0\.10\./
            stream.end = Buffer.byteLength file.toString('utf8')
        else
            stream.end = Buffer.byteLength file
        return stream
    else
        return file


cozyFileAdapter =

    attach: (id, file, data, callback) ->
        [data, callback] = [null, data] if typeof(data) is "function"
        urlPath = "data/#{id}/attachments/"
        file = fixForBuffer file
        client.sendFile urlPath, file, data, (error, response, body) ->
            try body = JSON.parse(body)
            checkError error, response, body, 201, callback

    get: (id, filename, callback) ->
        urlPath = "data/#{id}/attachments/#{encodeURIComponent filename}"
        output = new LaterStream callback
        client.saveFileAsStream urlPath, output.onReadableReady
        return output

    remove: (id, filename, callback) ->
        urlPath = "data/#{id}/attachments/#{encodeURIComponent filename}"
        client.del urlPath, (error, response, body) ->
            checkError error, response, body, 204, callback

cozyBinaryAdapter =

    attach: (id, file, data, callback) ->
        [data, callback] = [null, data] if typeof(data) is "function"
        urlPath = "data/#{id}/binaries/"
        file = fixForBuffer file
        client.sendFile urlPath, file, data, (error, response, body) ->
            try body = JSON.parse(body)
            checkError error, response, body, 201, callback

    get: (id, filename, callback) ->
        urlPath = "data/#{id}/binaries/#{encodeURIComponent filename}"
        output = new LaterStream callback
        client.saveFileAsStream urlPath, output.onReadableReady
        return output

    remove: (id, filename, callback) ->
        urlPath = "data/#{id}/binaries/#{encodeURIComponent filename}"
        client.del urlPath, (error, response, body) ->
            checkError error, response, body, 204, callback

cozyRequestsAdapter =

    define: (name, request, callback) ->
        docType = @getDocType()
        {map, reduce} = request

        # transforms all functions in anonymous functions
        # function named(a, b){...} --> function (a, b){...}
        # function (a, b){...} --> function (a, b){...}
        if reduce? and typeof reduce is 'function'
            reduce = reduce.toString()
            reduceArgsAndBody = reduce.slice reduce.indexOf '('
            reduce = "function #{reduceArgsAndBody}"

        view =
            reduce: reduce
            map: """
                function (doc) {
                  if (doc.docType.toLowerCase() === "#{docType}") {
                    filter = #{map.toString()};
                    filter(doc);
                  }
                }
            """

        path = "request/#{docType}/#{name.toLowerCase()}/"
        client.put path, view, (error, response, body) ->
            checkError error, response, body, 200, callback

    run: (name, params, callback) ->
        [params, callback] = [{}, params] if typeof(params) is "function"
        docType = @getDocType()

        path = "request/#{docType}/#{name.toLowerCase()}/"
        client.post path, params, (error, response, body) ->
            if error
                callback error
            else if response.statusCode isnt 200
                callback new Error util.inspect body
            else
                callback null, body

    remove: (name, callback) ->
        docType = @getDocType()
        path = "request/#{docType}/#{name.toLowerCase()}/"
        client.del path, (error, response, body) ->
            checkError error, response, body, 204, callback

    requestDestroy: (name, params, callback) ->
        [params, callback] = [{}, params] if typeof(params) is "function"
        params.limit ?= 100
        docType = @getDocType()

        path = "request/#{docType}/#{name.toLowerCase()}/destroy/"
        client.put path, params, (error, response, body) ->
            checkError error, response, body, 204, callback


# Public: a model backed by the cozy data-system
#    expose the complete {Model} interface
module.exports = class CozyBackedModel extends Model
    @adapter         : cozyDataAdapter
    @indexAdapter    : cozyIndexAdapter
    @fileAdapter     : cozyFileAdapter
    @binaryAdapter   : cozyBinaryAdapter
    @requestsAdapter : cozyRequestsAdapter

    @cast: ->
        unless @__addedToSchema
            @__addedToSchema = true
            @schema._id = String
            @schema._attachments = Object
            @schema._rev = String
            @schema.id = String
            @schema.docType = String
            @schema.binaries = Object

        super

    # Convert binary from _attachment to binary
    @convertBinary: (id, callback) ->
        url = "data/#{id}/binaries/convert"
        client.get url, (error, response, body) ->
            if error
                callback error
            else if response.statusCode is 404
                callback new Error "Document not found"
            else if response.statusCode isnt 200
                callback new Error "Server error occured."
            else
                callback()

    convertBinary: (cb) ->
        @constructor.convertBinary.call @constructor, @id, cb
