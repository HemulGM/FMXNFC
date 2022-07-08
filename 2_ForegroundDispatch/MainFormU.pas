unit MainFormU;

interface

uses
  Androidapi.JNI.Nfc,
  Androidapi.JNI.GraphicsContentViewText,
  Androidapi.JNI.App,
  FMX.Platform,
  System.Messaging,
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls, FMX.Layouts, FMX.ListBox, NFCHelper,
  FMX.Edit, FMX.Controls.Presentation;

type
  TMainForm = class(TForm)
    NFCTagIdLabel: TLabel;
    PromptLabel: TLabel;
    TagWriteEdit: TEdit;
    TagWriteButton: TButton;
    NfcCheckBox: TCheckBox;
    InfoList: TListBox;
    procedure FormCreate(Sender: TObject);
    procedure FormActivate(Sender: TObject);
    procedure TagWriteButtonClick(Sender: TObject);
    procedure NfcCheckBoxChange(Sender: TObject);
  private
    { Private declarations }
    NfcAdapter: JNfcAdapter;
    NFCSettingsChecked: Boolean;
    PendingIntent: JPendingIntent;
    // Proxy for calling NfcAdapter.enableForegroundDispatch
    procedure EnableForegroundDispatch;
    var AppEvents: IFMXApplicationEventService;
    function ApplicationEventHandler(AAppEvent: TApplicationEvent;
      AContext: TObject): Boolean;
  public
    { Public declarations }
    MessageSubscriptionID: Integer;
    procedure HandleIntentMessage(const Sender: TObject; const M: TMessage);
    procedure OnNewNfcIntent(Intent: JIntent);
  end;

var
  MainForm: TMainForm;

implementation

{$R *.fmx}

uses
  System.TypInfo,
  FMX.Platform.Android,
  Androidapi.Helpers,
  Androidapi.JNIBridge,
  Androidapi.Jni,
  Androidapi.JNI.JavaTypes,
  Androidapi.JNI.Os,
  Androidapi.JNI.Toast;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
var
  ClassIntent: JIntent;
begin
  Log.d('OnCreate');
  NFCSettingsChecked := False;
  //Set up event that triggers when app is brought back to foreground
  if TPlatformServices.Current.SupportsPlatformService(
       IFMXApplicationEventService,
       IInterface(AppEvents)) then
  begin
    AppEvents.SetApplicationEventHandler(ApplicationEventHandler);
  end;
  // Subscribe to the FMX message that is sent when onNewIntent is called
  // with an intent containing any of these 3 intent actions.
  // Support for this was added in Delphi 10 Seattle.
  MainActivity.registerIntentAction(TJNfcAdapter.JavaClass.ACTION_NDEF_DISCOVERED);
  MainActivity.registerIntentAction(TJNfcAdapter.JavaClass.ACTION_TECH_DISCOVERED);
  MainActivity.registerIntentAction(TJNfcAdapter.JavaClass.ACTION_TAG_DISCOVERED);
  MessageSubscriptionID := TMessageManager.DefaultManager.SubscribeToMessage(
    TMessageReceivedNotification, HandleIntentMessage);
  NfcAdapter := TJNfcAdapter.JavaClass.getDefaultAdapter(TAndroidHelper.Context);
  if NfcAdapter = nil then
  begin
    // Could do with exiting here maybe...
    raise Exception.Create('No NFC adapter present');
  end;
  // Set up the pending intent needed for enabling NFC foreground dispatch
  ClassIntent := TJIntent.JavaClass.init(TAndroidHelper.Context, TAndroidHelper.Activity.getClass);
  PendingIntent := TJPendingIntent.JavaClass.getActivity(TAndroidHelper.Context, 0,
    ClassIntent.addFlags(TJIntent.JavaClass.FLAG_ACTIVITY_SINGLE_TOP), 0);
end;

procedure TMainForm.FormActivate(Sender: TObject);
var
  Intent: JIntent;
begin
  Log.d('OnActivate');
  Intent := TAndroidHelper.Activity.getIntent;
  if not TJIntent.JavaClass.ACTION_MAIN.equals(Intent.getAction) then
  begin
    Log.d('Passing along received intent');
    OnNewNfcIntent(Intent);
  end;
end;

{$REGION 'JNI substitute for calling NfcAdapter.enableForegroundDispatch'}
procedure TMainForm.EnableForegroundDispatch;
var
  PEnv: PJniEnv;
  AdapterClass: JNIClass;
  NfcAdapterObject, PendingIntentObject: JNIObject;
  MethodID: JNIMethodID;
begin
  // We can't just call the imported NfcAdapter method enableForegroundDispatch
  // as it will crash due to a shortcoming in the JNI Bridge, which does not
  // support 2D array parameters. So instead we call it via a manual JNI call.
  PEnv := TJNIResolver.GetJNIEnv;
  NfcAdapterObject := (NfcAdapter as ILocalObject).GetObjectID;
  PendingIntentObject := (PendingIntent as ILocalObject).GetObjectID;
  AdapterClass := PEnv^.GetObjectClass(PEnv, NfcAdapterObject);
  // Get the signature with:
  // javap -s -classpath <path_to_android_platform_jar> android.nfc.NfcAdapter
  MethodID := PEnv^.GetMethodID(
    PEnv, AdapterClass, 'enableForegroundDispatch',
    '(Landroid/app/Activity;Landroid/app/PendingIntent;' +
    '[Landroid/content/IntentFilter;[[Ljava/lang/String;)V');
  // Clean up
  PEnv^.DeleteLocalRef(PEnv, AdapterClass);
  // Finally call the target Java method
  PEnv^.CallVoidMethodA(PEnv, NfcAdapterObject, MethodID,
    PJNIValue(ArgsToJNIValues([JavaContext, PendingIntentObject, nil, nil])));
end;
{$ENDREGION}

procedure TMainForm.NfcCheckBoxChange(Sender: TObject);
begin
  if NfcAdapter <> nil then
  begin
    if NfcCheckBox.IsChecked then
      EnableForegroundDispatch
    else
      NfcAdapter.disableForegroundDispatch(TAndroidHelper.Activity)
  end;
end;

function TMainForm.ApplicationEventHandler(AAppEvent: TApplicationEvent;
  AContext: TObject): Boolean;
begin
  Log.d('', Self, 'ApplicationEventHandler', Format('+ %s',
    [GetEnumName(TypeInfo(TApplicationEvent), Integer(AAppEvent))]));
  Result := True;
  case AAppEvent of
    TApplicationEvent.FinishedLaunching:
    begin
      //
    end;
    TApplicationEvent.BecameActive:
    begin
      if NfcAdapter <> nil then
      begin
        if not NfcAdapter.isEnabled then
        begin
          if not NFCSettingsChecked then
          begin
            Toast('NFC is not enabled.' + LineFeed + 'Launching NFC settings.');
            TAndroidHelper.Activity.startActivity(
              TJIntent.JavaClass.init(StringToJString('android.settings.NFC_SETTINGS')));
            NFCSettingsChecked := True;
          end
          else
          begin
            NfcCheckBox.Enabled := False;
            Toast('NFC functionality not available in this application due to system settings.');
          end;
        end
        else if NfcCheckBox.IsChecked then
          EnableForegroundDispatch
      end;
    end;
    TApplicationEvent.WillBecomeInactive:
    begin
      if NfcCheckBox.IsChecked and (NfcAdapter <> nil) then
        NfcAdapter.disableForegroundDispatch(TAndroidHelper.Activity);
    end;
    TApplicationEvent.WillTerminate:
    begin
      //
    end;
  end;
  Log.d('', Self, 'ApplicationEventHandler', '-');
end;

procedure TMainForm.HandleIntentMessage(const Sender: TObject;
  const M: TMessage);
var
  Intent: JIntent;
begin
  if M is TMessageReceivedNotification then
  begin
    Intent := TMessageReceivedNotification(M).Value;
    if Intent <> nil then
    begin
      if TJNfcAdapter.JavaClass.ACTION_NDEF_DISCOVERED.equals(Intent.getAction) or
         TJNfcAdapter.JavaClass.ACTION_TECH_DISCOVERED.equals(Intent.getAction) or
         TJNfcAdapter.JavaClass.ACTION_TAG_DISCOVERED.equals(Intent.getAction) then
      begin
        OnNewNfcIntent(Intent);
      end;
    end;
  end;
end;

procedure TMainForm.OnNewNfcIntent(Intent: JIntent);
var
  TagParcel: JParcelable;
  Tag: JTag;
begin
  Log.d('TMainForm.OnNewIntent');
  TAndroidHelper.Activity.setIntent(Intent);
  Log.d('Intent action = %s', [JStringToString(Intent.getAction)]);
  PromptLabel.Visible := False;
  Log.d('Getting Tag parcel from the received Intent');
  TagParcel := Intent.getParcelableExtra(TJNfcAdapter.JavaClass.EXTRA_TAG);
  if TagParcel <> nil then
  begin
    Log.d('Wrapping tag from the parcel');
    Tag := TJTag.Wrap(TagParcel);
  end;
  InfoList.Items.Clear;
  NFCTagIdLabel.Text := HandleNfcTag(Tag,
    procedure (const Msg: string)
    var
      Strings: TStrings;
      I: Integer;
    begin
      Strings := TStringList.Create;
      try
        Strings.Text := Msg;
        for I := 0 to Pred(Strings.Count) do
        begin
          Log.d('Adding to UI: ' + Strings[I]);
          InfoList.Items.Add(Strings[I]);
        end;
      finally
        Strings.Free;
      end;
    end);
  InfoList.Visible := True;
end;

procedure TMainForm.TagWriteButtonClick(Sender: TObject);
var
  TagParcel: JParcelable;
  Tag: JTag;
  Intent: JIntent;
begin
  if (NfcAdapter <> nil) and NfcAdapter.isEnabled then
  begin
    Intent := TAndroidHelper.Activity.getIntent;
    TagParcel := Intent.getParcelableExtra(TJNfcAdapter.JavaClass.EXTRA_TAG);
    if TagParcel <> nil then
    begin
      Log.d('Wrapping tag from the parcel');
      Tag := TJTag.Wrap(TagParcel);
      if not WriteTagText(TagWriteEdit.Text, Tag) then
        raise Exception.Create('Error connecting to tag');
    end;
  end
  else
    raise Exception.Create('NFC is not available');
end;

end.
