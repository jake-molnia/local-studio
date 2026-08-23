import { redirect } from "next/navigation";

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ section?: string }>;
}) {
  const params = await searchParams;
  redirect(params.section === "server" ? "/settings#controller" : "/settings#machines");
}
