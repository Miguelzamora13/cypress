import type { ReadableSpan } from '@opentelemetry/sdk-trace-base'

import type {
  OTLPExporterNodeConfigBase,
  OTLPExporterError,
} from '@opentelemetry/otlp-exporter-base'

import { diag } from '@opentelemetry/api'

import { OTLPTraceExporter as OTLPTraceExporterHttp } from '@opentelemetry/exporter-trace-otlp-http'

import { sendWithHttp } from '@opentelemetry/otlp-exporter-base'

export interface OTLPExporterNodeConfigBasePlusEncryption extends OTLPExporterNodeConfigBase {
  encryption?: {
    encryptRequest: (requestOptions: {
      url: string
      method: string
      body: string
    }) => (Promise<{jwe: string}>)
  }
}

/**
 * Collector Trace Exporter for Node
 */
export class OTLPTraceExporter extends OTLPTraceExporterHttp {
  delayedItemsToExport: {
    serviceRequest: string
    onSuccess: () => void
    onError: (error: OTLPExporterError) => void
  }[]
  enc: OTLPExporterNodeConfigBasePlusEncryption['encryption'] | undefined
  sendWithHttp: typeof sendWithHttp
  constructor (config: OTLPExporterNodeConfigBasePlusEncryption = {}) {
    super(config)
    this.enc = config.encryption
    this.delayedItemsToExport = []
    this.sendWithHttp = sendWithHttp
    if (this.enc) {
      this.headers['x-cypress-encrypted'] = '1'
    }
  }

  /**
   * Adds the projectId as a header and exports any delayed spans.
   * @param projectId - the id of the project to export spans for.
   */
  attachProjectId (projectId: string | null | undefined): void {
    if (!projectId) {
      return
    }

    this.headers['x-project-id'] = projectId
    this.sendDelayedItems()
  }

  /**
   * Adds the recordKey as a header and exports any delayed spans.
   * @param recordKey - the recordKey of the project to export spans for.
   */
  attachRecordKey (recordKey: string | null | undefined): void {
    if (!recordKey) {
      return
    }

    this.headers['x-record-key'] = recordKey
    this.sendDelayedItems()
  }

  /**
   * exports delayed spans if both the record key and project id are present
   */
  sendDelayedItems () {
    if (this.headers['x-project-id'] && this.headers['x-record-key']) {
      this.delayedItemsToExport.forEach((item) => {
        this.send(item.serviceRequest, item.onSuccess, item.onError)
      })

      this.delayedItemsToExport = []
    }
  }

  /**
   * Overrides send if we need to encrypt the request.
   * @param objects
   * @param onSuccess
   * @param onError
   * @returns
   */
  send (
    objects: ReadableSpan[] | string,
    onSuccess: () => void,
    onError: (error: OTLPExporterError) => void,
  ): void {
    if (this._shutdownOnce.isCalled) {
      diag.debug('Shutdown already started. Cannot send objects')

      return
    }

    let serviceRequest: string

    if (typeof objects !== 'string') {
      serviceRequest = JSON.stringify(this.convert(objects))
    } else {
      serviceRequest = objects
    }

    // Delay items if we want encryption but don't have a project id and a record key
    if (this.enc && !(this.headers['x-project-id'] && this.headers['x-record-key'])) {
      this.delayedItemsToExport.push({ serviceRequest, onSuccess, onError })

      return
    }

    const prepareRequest = (request: string): Promise<string> => {
      if (this.enc) {
        return this.enc.encryptRequest({ url: this.url, method: 'post', body: serviceRequest }).then(({ jwe }) => JSON.stringify(jwe))
      }

      return Promise.resolve(request)
    }

    const promise = prepareRequest(serviceRequest).then((body) => {
      return new Promise<void>((resolve, reject) => {
        this.sendWithHttp(
          this,
          body,
          'application/json',
          resolve,
          reject,
        )
      })
    }).then(onSuccess, onError)

    this._sendingPromises.push(promise)
    const popPromise = () => {
      const index = this._sendingPromises.indexOf(promise)

      this._sendingPromises.splice(index, 1)
    }

    promise.then(popPromise, popPromise)
  }
}
