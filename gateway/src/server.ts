import Fastify, {type FastifyInstance} from 'fastify';
import {operations} from './catalog.js';
import {BridgeError} from './errors.js';
import {BridgeService} from './service.js';
import {validateArguments, isObject} from './validation.js';
import {mountMcp} from './mcp.js';
export interface ServerOptions {service: BridgeService; allowedHosts?: string[]; port?: number; mcp?: boolean}
export async function buildServer(options: ServerOptions): Promise<FastifyInstance> {
  const app = Fastify({logger:false,bodyLimit:1024*1024,requestTimeout:30000,connectionTimeout:30000,
    routerOptions:{maxParamLength:2048},ajv:{customOptions:{coerceTypes:false,removeAdditional:false}}});
  app.addHook('onRequest',async (request,reply) => {
    reply.header('Cache-Control','no-store');
    reply.header('X-Content-Type-Options','nosniff');
    const address = app.server.address();
    const port = typeof address === 'object' && address ? address.port : options.port ?? 21420;
    const hosts = options.allowedHosts ?? [`127.0.0.1:${port}`,`localhost:${port}`,`[::1]:${port}`];
    if (!request.headers.host || !hosts.includes(request.headers.host.toLowerCase())) throw new BridgeError(403,'permission_denied','The request Host is not allowed.');
    // This service accepts agent connections, not browser requests; no CORS is enabled.
    if (request.headers.origin) throw new BridgeError(403,'permission_denied','Browser origins are not allowed.');
    options.service.authenticate(request.headers.authorization);
  });
  app.setErrorHandler((error,request,reply) => {
    let safe: BridgeError;
    if (error instanceof BridgeError) safe = error;
    else if (isObject(error) && error.code === 'FST_ERR_CTP_BODY_TOO_LARGE') safe = new BridgeError(413,'request_too_large','The request exceeds the size limit.');
    else if (isObject(error) && typeof error.statusCode === 'number' && error.statusCode >= 400 && error.statusCode < 500) safe = new BridgeError(error.statusCode,'invalid_arguments','The request is invalid.');
    else safe = new BridgeError(503,'adapter_unavailable','The service could not complete the operation.');
    if (safe.status === 401) reply.header('WWW-Authenticate','Bearer realm="iBridge"');
    reply.code(safe.status).send(safe.toEnvelope());
  });
  app.setNotFoundHandler(async () => {throw new BridgeError(404,'not_found','Unknown API route.');});
  app.get('/api/v1/system/capabilities',async request => {
    if (Object.keys(request.query as object).length) throw new BridgeError(400,'invalid_arguments','This route takes no query arguments.');
    return options.service.capabilities(options.service.authenticate(request.headers.authorization));
  });
  for (const op of operations) {
    app.route({method:op.method,url:'/api/v1'+op.path.replace(/\{([^}]+)\}/g,':$1'),handler:async request => {
      let args: Record<string, unknown>;
      if (op.method === 'GET') {
        args = validateArguments(op,{...(request.query as object),...(request.params as object)},true);
      } else {
        if (Object.keys(request.query as object).length) throw new BridgeError(400,'invalid_arguments','Writes take no query arguments.');
        if (!isObject(request.body)) throw new BridgeError(400,'invalid_arguments','A JSON object is required.');
        if (Object.hasOwn(request.body,'request_id') || op.path_keys.some(key => Object.hasOwn(request.body as object,key))) throw new BridgeError(400,'invalid_arguments','Path IDs and the request ID must not be duplicated in the body.');
        args = {...request.body,...request.params as object,request_id:request.headers['idempotency-key']};
      }
      return options.service.execute(options.service.authenticate(request.headers.authorization),op.name,args);
    }});
  }
  if (options.mcp !== false) await mountMcp(app,options.service);
  return app;
}
