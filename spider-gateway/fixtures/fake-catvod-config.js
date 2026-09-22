// Minimal CatVod route with mutable initialization state and guest-cookie setup.
var A=null,B=1,D={},activeExt="",guestCookie;async function C(t){A={
register(){},async ready(){guestCookie=t.biliCookie;},async close(){},inject(){
const response=value=>({body:JSON.stringify(value),statusCode:200,json(){return value;}});
return {get:async()=>response({video:{sites:[{key:"config",api:"/spider/config/3"}]}}),
post(route){return {payload:async payload=>{
if(route.endsWith("/init")){activeExt=payload.ext;if(activeExt==="fail")throw new Error("fixture init failed");return response({});}
if(route.endsWith("/home")){
 if(activeExt==="guest")guestCookie.includes("session");
 return response({class:[{type_id:"movie",type_name:"电影"}],list:[{vod_id:activeExt,vod_name:activeExt}]});
}
return response({});}};}};}
},A.register(D),A.listen({port:process.env.DEV_HTTP_PORT||0,host:"127.0.0.1"})}async function E(){A&&(await A.close()),A=null}0&&(module.exports={start,stop});
