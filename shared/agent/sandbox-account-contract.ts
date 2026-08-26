import { Schema } from "effect";

export const SandboxProviderSchema = Schema.Union([
  Schema.Literal("modal"),
  Schema.Literal("daytona"),
]);

export const SandboxAccountEntrySchema = Schema.Struct({
  id: Schema.String,
  provider: SandboxProviderSchema,
  label: Schema.String,
  endpoint: Schema.String,
  connectedAt: Schema.String,
  secretProvider: Schema.String,
  image: Schema.optional(Schema.NullOr(Schema.String)),
});

export const SandboxAccountsResponseSchema = Schema.Struct({
  accounts: Schema.Array(SandboxAccountEntrySchema),
});

export type SandboxProvider = typeof SandboxProviderSchema.Type;
export type SandboxAccountEntry = typeof SandboxAccountEntrySchema.Type;
