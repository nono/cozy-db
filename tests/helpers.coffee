CozyAdapter = require('../src/index')

Client = require("request-json").JsonClient
client = new Client "http://localhost:9101/"
client.setBasicAuth "test", "apptoken"


exports.createDoc = (data, callback) ->
    if CozyAdapter.CozyModel.db # pouchd
        CozyAdapter.CozyModel.db.post data, (err, info) ->
            callback err, _id: info?.id
    else # DS
        console.log "CREATE DOC DS", data
        client.post '/data/', data, (err, res, created) ->
            console.log "CREATED ", created
            callback err, created

exports.deleteDoc = (id, callback) ->
    if CozyAdapter.CozyModel.db # pouchd
        CozyAdapter.CozyModel.db.get id, (err, doc) ->
            if err and err.status is 404
                callback null
            else if err
                callback err
            else
                CozyAdapter.CozyModel.db.remove doc, callback
    else # DS
        console.log "DELETE DOC DS", data
        client.del "/data/#{id}/", (err, res, body) ->
            console.log "DELETED", err, res.statusCode, body
            callback err

exports.clearDocType = (doctype) -> (callback) ->
    klass = CozyAdapter.getModel doctype, CozyAdapter.NoSchema
    klass.defineRequest 'all', CozyAdapter.defaultRequests.all, (err) ->
        return callback err if err
        klass.requestDestroy 'all', (err) ->
            return callback err if err
            klass.removeRequest 'all', callback

exports.createDocWithID = (data, id, callback) ->
    id = '' + id
    if CozyAdapter.CozyModel.db # pouchd
        CozyAdapter.CozyModel.db.get id, (err, doc) ->

            data._id = id

            if err and err.reason is 'deleted'
                opts = {open_revs: 'all'}
                CozyAdapter.CozyModel.db.get id, opts, (err, revs) ->
                    data._rev = revs[0].ok._rev
                    CozyAdapter.CozyModel.db.put data, callback

            else if err and err.reason is 'missing'
                CozyAdapter.CozyModel.db.put data, callback

            else if err
                callback err

            else
                data._rev = doc._rev
                CozyAdapter.CozyModel.db.put data, callback
    else
        client.post "data/#{id}/", data, callback