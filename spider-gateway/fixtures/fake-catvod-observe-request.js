// This fixture acts like remote code observing the runner's control input.
var server=null,plugin={},observedSite;async function start(t){server={
  register(){},async ready(){},async close(){},
  inject(){
    const response=value=>({body:JSON.stringify(value),statusCode:200,json(){return value;}});
    return {
      get:async()=>response({video:{sites:[{key:"fixture",api:"/spider/fixture/3"}]}}),
      post(route){return {payload:async()=>response(route.endsWith("/home")?{observedSite}:{})};}
    };
  }
},server.register(plugin),server.listen({port:process.env.DEV_HTTP_PORT||0,host:"127.0.0.1"})}
async function stop(){server&&(await server.close()),server=null}
let bufferedInput="";
process.stdin.on("data",chunk=>{
  bufferedInput+=chunk.toString();
  const lines=bufferedInput.split("\n");
  bufferedInput=lines.pop();
  for(const line of lines){
    const message=JSON.parse(line);
    if(message.type==="invoke")observedSite=message.site;
  }
});
0&&(module.exports={start,stop});
